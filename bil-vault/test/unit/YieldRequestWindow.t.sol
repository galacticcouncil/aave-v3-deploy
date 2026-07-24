// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @title Yield Request-to-Execute Window — Regression Coverage
/// @notice Verifies that totalAssets and the exchange rate stay flat across
///         the admin-approval delay between requestYieldWithdrawal (T2) and
///         executeYieldWithdrawal (T3). Pre-fix, the vault's bucket kept
///         accruing yield during this window even though Decentral had locked
///         the payout amount at T2 — when the actual yield arrived at T3, the
///         vault dropped its inflated accrual and the rate ticked down.
contract YieldRequestWindowTest is BaseTest {
    /// @dev Per-position pendingYield via the public struct getter (last tuple element).
    function _pendingYield(uint256 idx) internal view returns (uint256 py) {
        (,,,,,,,, py) = vault.positions(idx);
    }

    /// @dev Bring position 0 to YieldWithdrawalRequested.
    function _toYWR(address user, uint256 amount) internal {
        _deposit(user, amount);
        _warpDays(61);
        vault.pokeDecentral(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   CORE: totalAssets / rate stable across the [T2, T3] window
    // ═══════════════════════════════════════════════════════════════════════

    function test_totalAssetsFlatAcrossRequestExecuteWindow() public {
        _toYWR(alice, 100_000e18);

        uint256 totalAtT2 = vault.totalAssets();
        uint256 rateAtT2 = vault.exchangeRate();

        // Walk forward through 47 hours of admin-approval delay
        for (uint256 hr = 1; hr <= 47; hr++) {
            vm.warp(block.timestamp + 1 hours);
            assertApproxEqAbs(
                vault.totalAssets(),
                totalAtT2,
                1,
                "totalAssets() drifted across yield-request window"
            );
            assertApproxEqAbs(
                vault.exchangeRate(),
                rateAtT2,
                1,
                "exchangeRate() drifted across yield-request window"
            );
        }
    }

    /// @notice Even a 1-week admin delay produces no rate change.
    function test_longApprovalDelay_noRateMovement() public {
        _toYWR(alice, 100_000e18);
        uint256 rateAtT2 = vault.exchangeRate();

        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(vault.exchangeRate(), rateAtT2, 1, "rate flat after 1-week delay");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   EXECUTE doesn't drop the rate (the bug's symptom)
    // ═══════════════════════════════════════════════════════════════════════

    function test_executeDoesNotDropRate_withApprovalDelay() public {
        _toYWR(alice, 100_000e18);

        // Long approval delay
        vm.warp(block.timestamp + 24 hours);

        uint256 rateBefore = vault.exchangeRate();

        // Approve and execute. Under H-01 fix, pendingYield is capped at
        // maturityTime (60d) but the mock pays out at its own continuously-
        // accruing schedule (61d worth, because _toYWR warped 61 days before
        // requesting). The 1-day surplus is benign — it lifts the rate (the
        // existing comment in pokeDecentral notes this surplus path
        // explicitly). Tolerate the upward rate movement; assert only that
        // the rate did not DROP — that's the bug the original test guarded.
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        uint256 rateAfter = vault.exchangeRate();
        assertGe(rateAfter, rateBefore, "rate must not drop across yield-execute");
        // Surplus is small (one day of yield on the 1.18x-APR-on-100k position
        // divided over total supply). Bound it conservatively.
        assertLt(
            rateAfter - rateBefore,
            5e15, // 0.5% of WAD
            "surplus from maturity-cap is bounded"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PENDING YIELD bookkeeping
    // ═══════════════════════════════════════════════════════════════════════

    function test_pendingYieldSetAtRequest_clearedAtExecute() public {
        _deposit(alice, 100_000e18);
        _warpDays(61);

        // Before request: no pending
        assertEq(vault.totalPendingYield(), 0, "no pending before request");
        assertEq(_pendingYield(0), 0, "pos.pendingYield = 0 before request");

        // Trigger request
        vault.pokeDecentral(0);

        // After request: pending = expected yield over [T0, maturityTime].
        // Audit H-01 fix: pendingYield is capped at the 60-day maturity, not
        // the 61-day call timestamp — phantom post-maturity accrual is no
        // longer recorded.
        uint256 expected = (100_000e18 * APY_18_PERCENT * 60 * SECONDS_PER_DAY) / (365 days * 1e18);
        assertApproxEqRel(vault.totalPendingYield(), expected, 0.001e18, "totalPendingYield set (capped at maturity)");
        assertApproxEqRel(_pendingYield(0), expected, 0.001e18, "pos.pendingYield set (capped at maturity)");

        // Yield bookkeeping in bucket should be zero (we removed it)
        assertEq(vault.yieldRateSum(), 0, "bucket yield cleared at request");

        // Execute
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        // After execute: pending cleared, idle holds the actual yield
        assertEq(vault.totalPendingYield(), 0, "pending cleared at execute");
        assertEq(_pendingYield(0), 0, "pos.pendingYield reset");
        assertGt(vault.idleHollar(), 0, "idle has actual yield received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ACCOUNTING INVARIANT after fix
    // ═══════════════════════════════════════════════════════════════════════

    function test_totalAssetsFormulaIncludesPendingYield() public {
        _deposit(alice, 100_000e18);
        _warpDays(61);
        vault.pokeDecentral(0); // → YWR, sets pendingYield

        uint256 invested = vault.totalInvestedPrincipal();
        uint256 idle = vault.idleHollar();
        uint256 pending = vault.totalPendingYield();

        // No active yield bucket (cleared at request); accruedYield = 0
        // totalAssets must equal invested + idle + pending
        assertEq(
            vault.totalAssets(),
            invested + idle + pending,
            "totalAssets includes pendingYield"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FULL LIFECYCLE: rate is monotonic non-decreasing across delays
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullLifecycle_rateMonotonic_withDelays() public {
        _deposit(alice, 100_000e18);
        uint256 rPrev = vault.exchangeRate();

        // Accrue
        _warpDays(60);
        uint256 rMature = vault.exchangeRate();
        assertGe(rMature, rPrev, "rate grows during accrual");
        rPrev = rMature;

        // Request yield (T2)
        vault.pokeDecentral(0);
        uint256 rRequest = vault.exchangeRate();
        assertApproxEqAbs(rRequest, rPrev, 1, "rate flat at request");
        rPrev = rRequest;

        // Long approval delay (this is where the bug used to bite)
        vm.warp(block.timestamp + 24 hours);
        uint256 rDelayed = vault.exchangeRate();
        assertApproxEqAbs(rDelayed, rPrev, 1, "rate flat across approval delay");
        rPrev = rDelayed;

        // Execute (T3)
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);
        uint256 rExecute = vault.exchangeRate();
        assertApproxEqAbs(rExecute, rPrev, 10, "rate flat across execute");
        rPrev = rExecute;

        // Principal redemption (still flat)
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        vault.pokeDecentral(0);
        uint256 rRedeem = vault.exchangeRate();
        assertApproxEqAbs(rRedeem, rPrev, 10, "rate flat across principal redeem");
    }
}
