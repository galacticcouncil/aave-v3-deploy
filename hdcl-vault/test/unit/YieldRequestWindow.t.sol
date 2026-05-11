// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title Yield Request-to-Execute Window — Regression Coverage
/// @notice Verifies that totalAssets and the exchange rate stay flat across
///         the admin-approval delay between requestYieldWithdrawal (T2) and
///         executeYieldWithdrawal (T3). Pre-fix, the vault's bucket kept
///         accruing yield during this window even though Decentral had locked
///         the payout amount at T2 — when the actual yield arrived at T3, the
///         vault dropped its inflated accrual and the rate ticked down.
contract YieldRequestWindowTest is BaseTest {
    /// @dev Per-position pendingYield via low-level call (struct getter index 11).
    function _pendingYield(uint256 idx) internal view returns (uint256 py) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok);
        // 12 fields, each 32 bytes. pendingYield = word 11 (last).
        // 32 (length prefix) + 11*32 = 384
        assembly {
            py := mload(add(data, 384))
        }
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

        // Approve and execute
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        uint256 rateAfter = vault.exchangeRate();
        assertApproxEqAbs(rateAfter, rateBefore, 10, "rate flat across yield-execute");
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

        // After request: pending = expected yield over [T0, T2]
        uint256 expected = (100_000e18 * APY_18_PERCENT * 61 * SECONDS_PER_DAY) / (365 days * 1e18);
        assertApproxEqRel(vault.totalPendingYield(), expected, 0.001e18, "totalPendingYield set");
        assertApproxEqRel(_pendingYield(0), expected, 0.001e18, "pos.pendingYield set");

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
    //   STALE-DURING-YWR: pending yield moves into stale value
    // ═══════════════════════════════════════════════════════════════════════

    function test_markStaleDuringYWR_movesPendingToStale() public {
        _toYWR(alice, 100_000e18);

        uint256 pending = _pendingYield(0);
        uint256 totalPendingBefore = vault.totalPendingYield();
        assertGt(pending, 0, "pending should be set");

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        // Pending cleared
        assertEq(vault.totalPendingYield(), totalPendingBefore - pending, "pending removed");
        assertEq(_pendingYield(0), 0, "pos.pendingYield cleared");

        // Stale value includes principal + the same pending amount as staleYield
        assertEq(vault.totalStaleValue(), 100_000e18 + pending, "stale value = principal + pending");
    }

    function test_unmarkStaleDuringYWR_restoresPending() public {
        _toYWR(alice, 100_000e18);
        uint256 pendingBefore = _pendingYield(0);

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        vm.prank(admin);
        vault.unmarkPositionStale(0);

        // Pending restored to original amount
        assertEq(_pendingYield(0), pendingBefore, "pos.pendingYield restored");
        assertEq(vault.totalPendingYield(), pendingBefore, "totalPendingYield restored");

        // Stale value cleared
        assertEq(vault.totalStaleValue(), 0, "stale cleared");
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
        uint256 stale = vault.totalStaleValue();
        uint256 pending = vault.totalPendingYield();

        // No active yield bucket (cleared at request); accruedYield = 0
        // totalAssets must equal invested + idle + stale + pending
        assertEq(
            vault.totalAssets(),
            invested + idle + stale + pending,
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
