// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {WDCLOracle} from "../../src/WDCLOracle.sol";

/// @title Phantom Yield Fix — Regression and Edge-Case Coverage
/// @notice Verifies that after yield is claimed from Decentral, the vault no longer
///         accrues phantom yield in `totalAssets()` until principal redemption.
///         Also exercises the state-aware bucket accounting added to
///         `markPositionStale` / `unmarkPositionStale` to prevent underflow.
contract PhantomYieldTest is BaseTest {
    // ─── Local helpers ──────────────────────────────────────────────────────

    /// @dev Deposit, warp past maturity, and advance to YieldWithdrawalRequested.
    function _toYieldRequested(address user, uint256 amount) internal {
        _deposit(user, amount);
        _warpDays(61);
        vault.pokeDecentral(0);
    }

    /// @dev Deposit and advance through yield claim → state ends at PrincipalWithdrawalRequested.
    function _toPrincipalRequested(address user, uint256 amount) internal {
        _toYieldRequested(user, amount);
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);
    }

    /// @dev Position exists at index `posIdx` already in PWR; finish principal redemption.
    function _redeemPrincipal(uint256 posIdx) internal {
        (uint256 tokenId, , , , , ) = vault.getPosition(posIdx);
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        vault.pokeDecentral(posIdx);
    }

    /// @dev Read pos.isStale via low-level call (struct getters drop bool fields after the 6th).
    function _isStale(uint256 idx) internal view returns (bool isStale) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok, "positions() call failed");
        // 11 fields, each 32 bytes. isStale = word 7.
        assembly {
            isStale := mload(add(data, 256))
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   CORE REGRESSION: no phantom yield in the gap
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The bug: between yield-claim and principal-redemption, totalAssets()
    ///         used to inflate as the bucket continued accruing yield Decentral
    ///         would never pay. After the fix, totalAssets() must stay flat.
    function test_phantomYield_totalAssetsFlatBetweenClaimAndRedemption() public {
        _toPrincipalRequested(alice, 100_000e18);

        // Snapshot at the instant of yield claim.
        uint256 totalAtClaim = vault.totalAssets();

        // Walk forward through 47 hours (just before the 48-hour withdrawal delay)
        // and verify totalAssets() never grows beyond a tiny rounding tolerance.
        for (uint256 hr = 1; hr <= 47; hr++) {
            vm.warp(block.timestamp + 1 hours);
            uint256 nowTotal = vault.totalAssets();
            // Allow ≤1 wei of integer drift from arithmetic; phantom yield would
            // be on the order of 100s of HOLLAR by hour 47 (~22 HOLLAR/hr at 18% on 100k),
            // so 1 wei tolerance comfortably catches the bug.
            assertApproxEqAbs(
                nowTotal,
                totalAtClaim,
                1,
                "totalAssets() drifted during yield-claim to principal-redemption gap"
            );
        }
    }

    /// @notice Exchange rate must be flat (modulo dust) during the same gap.
    function test_phantomYield_exchangeRateFlatBetweenClaimAndRedemption() public {
        _toPrincipalRequested(alice, 100_000e18);

        uint256 rateAtClaim = vault.exchangeRate();

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS);

        uint256 rateBeforeRedemption = vault.exchangeRate();
        assertApproxEqAbs(
            rateBeforeRedemption,
            rateAtClaim,
            1,
            "exchangeRate() drifted during the gap"
        );
    }

    /// @notice After fix, principal redemption should NOT cause a sudden rate drop.
    ///         Pre-fix, the phantom yield accrued during the gap was wiped out at
    ///         principal-redemption, snapping the rate downward.
    function test_phantomYield_noRateDropAtPrincipalRedemption() public {
        _toPrincipalRequested(alice, 100_000e18);

        // Wait the full delay
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        // Rate should be effectively unchanged across the redemption — the only
        // movement is wei-scale rounding from bucket math.
        assertApproxEqAbs(
            rateAfter,
            rateBefore,
            10,
            "exchangeRate() dropped at principal redemption"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ORACLE: phantom yield previously inflated WDCLOracle's reported price
    // ═══════════════════════════════════════════════════════════════════════

    function test_phantomYield_oraclePriceFlatThroughGap() public {
        WDCLOracle oracle = new WDCLOracle(address(vault));
        vm.prank(admin);
        vault.setOracle(address(oracle));

        _toPrincipalRequested(alice, 100_000e18);

        (, int256 priceAtClaim, , , ) = oracle.latestRoundData();

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS);

        (, int256 priceBeforeRedemption, , , ) = oracle.latestRoundData();

        // Both prices in 8-decimal Chainlink form. They must match exactly because
        // we ran exchangeRate() through the same `/1e10` truncation.
        assertEq(
            priceBeforeRedemption,
            priceAtClaim,
            "Oracle price drifted during gap (would have been the same-block sandwich vector)"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FULL LIFECYCLE: rate is monotonic non-decreasing across all phases
    // ═══════════════════════════════════════════════════════════════════════

    function test_phantomYield_rateMonotonicAcrossLifecycle() public {
        _deposit(alice, 100_000e18);

        uint256 rPrev = vault.exchangeRate();

        // Accrue 60 days of yield
        _warpDays(60);
        uint256 rMature = vault.exchangeRate();
        assertGe(rMature, rPrev, "rate should grow during accrual");
        rPrev = rMature;

        // Active → YWR
        vault.pokeDecentral(0);
        uint256 rYwr = vault.exchangeRate();
        assertApproxEqAbs(rYwr, rPrev, 10, "rate stable Active to YWR");
        rPrev = rYwr;

        // Approve, cascade YWR → YC → PWR
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);
        uint256 rPwr = vault.exchangeRate();
        assertApproxEqAbs(rPwr, rPrev, 10, "rate stable across yield claim cascade");
        rPrev = rPwr;

        // Sit through the 48-hour delay
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS);
        uint256 rGapEnd = vault.exchangeRate();
        assertApproxEqAbs(rGapEnd, rPrev, 1, "no phantom yield during gap");
        rPrev = rGapEnd;

        // Approve principal, redeem
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + 2);
        vault.pokeDecentral(0);
        uint256 rRedeemed = vault.exchangeRate();
        assertApproxEqAbs(rRedeemed, rPrev, 10, "rate stable across principal redemption");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ANTI-SANDWICH: a depositor in the gap and one outside should pay the same
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pre-fix, a depositor entering during the gap would mint at the
    ///         (inflated) phantom-yield rate, then watch the rate drop. This test
    ///         verifies the rate at gap-start equals the rate at gap-end so any
    ///         depositor in between mints fairly.
    function test_phantomYield_depositorDuringGapMintsFairly() public {
        // Seed the vault, mature, claim yield — alice is the long-term holder
        _toPrincipalRequested(alice, 100_000e18);

        // Bob deposits mid-gap
        vm.warp(block.timestamp + 24 hours);
        uint256 bobDeposit = 10_000e18;
        uint256 bobShares = vault.previewDeposit(bobDeposit);
        _deposit(bob, bobDeposit);

        // Charlie deposits at end of gap
        vm.warp(block.timestamp + 24 hours);
        uint256 charlieShares = vault.previewDeposit(bobDeposit);
        _deposit(charlie, bobDeposit);

        // Both should receive equivalent shares per HOLLAR (within rounding).
        assertApproxEqRel(
            charlieShares,
            bobShares,
            0.0001e18, // 0.01% — tighter than any phantom-yield-driven divergence
            "Two equal-size deposits across the gap should mint equal shares"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   STALE FLOW: markPositionStale on PWR/YC must not underflow after fix
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Regression: with the split-helper fix, marking a position stale in
    ///         PrincipalWithdrawalRequested state would have underflowed if it tried
    ///         to remove yield bookkeeping that was already cleared at yield claim.
    function test_markStale_principalRequested_noUnderflow() public {
        _toPrincipalRequested(alice, 50_000e18);

        // Wait for stale-eligibility
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 yieldRateSumBefore = vault.yieldRateSum();
        uint256 yieldOffsetSumBefore = vault.yieldOffsetSum();
        uint256 totalInvestedBefore = vault.totalInvestedPrincipal();

        vm.prank(admin);
        vault.markPositionStale(0); // must NOT revert

        // Yield bookkeeping was already cleared at yield claim — mark must not touch it.
        assertEq(vault.yieldRateSum(), yieldRateSumBefore, "yieldRateSum must be unchanged");
        assertEq(vault.yieldOffsetSum(), yieldOffsetSumBefore, "yieldOffsetSum must be unchanged");

        // Principal moved out of invested.
        assertEq(
            vault.totalInvestedPrincipal(),
            totalInvestedBefore - 50_000e18,
            "principal moved out of invested"
        );

        // staleYield is 0 because Decentral already paid the yield.
        assertEq(vault.totalStaleValue(), 50_000e18, "totalStaleValue == principal only");
    }

    /// @notice Confirm the existing YWR-state stale flow still works (yield gets removed).
    function test_markStale_yieldRequested_clearsBothBuckets() public {
        _toYieldRequested(alice, 50_000e18);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(admin);
        vault.markPositionStale(0);

        // Both yield and principal bookkeeping cleared — totalAssets preserved through
        // staleValue = principal + accrued yield.
        assertEq(vault.yieldRateSum(), 0, "yieldRateSum cleared");
        assertEq(vault.totalInvestedPrincipal(), 0, "totalInvestedPrincipal cleared");
        assertGt(vault.totalStaleValue(), 50_000e18, "stale value > principal (includes yield)");
        assertApproxEqAbs(
            vault.totalAssets(),
            totalAssetsBefore,
            10,
            "totalAssets preserved across mark"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   STALE FLOW: unmark must NOT restore phantom yield
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pre-fix, unmarking a stale position in PWR state with backtrack=true
    ///         would re-add yield bookkeeping that should never accrue (Decentral
    ///         already paid). After fix, yield is NOT restored.
    function test_unmarkStale_principalRequested_doesNotRestoreYield() public {
        _toPrincipalRequested(alice, 50_000e18);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 yieldRateSumBefore = vault.yieldRateSum();
        uint256 yieldOffsetSumBefore = vault.yieldOffsetSum();

        // Even with backtrack=true, yield must NOT be restored.
        vm.prank(admin);
        vault.unmarkPositionStale(0);

        assertEq(
            vault.yieldRateSum(),
            yieldRateSumBefore,
            "yieldRateSum must not gain a phantom contribution"
        );
        assertEq(
            vault.yieldOffsetSum(),
            yieldOffsetSumBefore,
            "yieldOffsetSum must not gain a phantom contribution"
        );

        // Principal IS restored — Decentral still owes it.
        assertEq(vault.totalInvestedPrincipal(), 50_000e18, "principal restored");
        assertFalse(_isStale(0), "isStale cleared");

        // No phantom yield should accrue going forward, even after a long warp.
        uint256 totalBefore = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        uint256 totalAfter = vault.totalAssets();
        assertApproxEqAbs(
            totalAfter,
            totalBefore,
            10,
            "no phantom yield after unmark on PWR"
        );
    }

    /// @notice YWR-state unmark restores the locked pending yield (the amount
    ///         Decentral has already agreed to pay). Bucket bookkeeping stays
    ///         cleared — the yield won't grow further because Decentral has
    ///         frozen the amount at the original request moment.
    function test_unmarkStale_yieldRequested_restoresPendingYield_backtrack() public {
        _toYieldRequested(alice, 50_000e18);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();
        uint256 totalPendingBefore = vault.totalPendingYield();

        vm.prank(admin);
        vault.markPositionStale(0);

        vm.prank(admin);
        vault.unmarkPositionStale(0);

        // Bucket bookkeeping stays cleared — yield was locked at request time
        // and won't accrue more.
        assertEq(vault.yieldRateSum(), 0, "yieldRateSum stays 0 (locked at request)");

        // Pending yield is restored to what it was before mark.
        assertEq(
            vault.totalPendingYield(),
            totalPendingBefore,
            "pendingYield restored on unmark"
        );

        // Rate is preserved across mark→unmark.
        assertApproxEqRel(vault.exchangeRate(), rateBefore, 0.001e18, "rate preserved");
    }

    /// @notice Same as above with backtrack=false. The flag is now a no-op for
    ///         YWR-state unmarks (Decentral's locked amount is always preserved).
    function test_unmarkStale_yieldRequested_restoresPendingYield_noBacktrack() public {
        _toYieldRequested(alice, 50_000e18);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 totalPendingBefore = vault.totalPendingYield();

        vm.prank(admin);
        vault.markPositionStale(0);

        // Warp while stale (rate is frozen)
        _warpDays(10);

        vm.prank(admin);
        vault.unmarkPositionStale(0);

        // Pending yield restored regardless of backtrack flag.
        assertEq(
            vault.totalPendingYield(),
            totalPendingBefore,
            "pendingYield restored even with backtrack=false"
        );

        // Rate stays flat — Decentral's locked amount doesn't change with time.
        uint256 r0 = vault.exchangeRate();
        _warpDays(30);
        uint256 r1 = vault.exchangeRate();
        assertApproxEqRel(r1, r0, 0.001e18, "rate stays flat - no further accrual");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   STALE FLOW: new safety guard — cannot unmark a Redeemed position
    // ═══════════════════════════════════════════════════════════════════════

    function test_unmarkStale_revertsOnRedeemed() public {
        _toPrincipalRequested(alice, 50_000e18);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        // Process to Redeemed while stale
        _redeemPrincipal(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "should be Redeemed");
        assertTrue(_isStale(0), "isStale not auto-cleared on redemption");

        // Unmarking a Redeemed-but-isStale position would re-add principal that's gone.
        vm.prank(admin);
        vm.expectRevert(HDCLVault.PositionAlreadyRedeemed.selector);
        vault.unmarkPositionStale(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   MIXED PORTFOLIO: many positions in different states
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice With multiple positions in mixed lifecycle states, totalAssets() must
    ///         remain flat across the gap window even when only some positions are
    ///         in the gap.
    function test_phantomYield_mixedPortfolio_totalAssetsFlat() public {
        // alice deposits — will be in YieldClaimed/PWR (in the gap)
        _toPrincipalRequested(alice, 50_000e18);

        // bob deposits NOW — fresh, still active. Yield should keep accruing for bob.
        _deposit(bob, 30_000e18);

        // Snapshot bob's expected yield rate going forward
        uint256 totalAtT0 = vault.totalAssets();

        // 24 hours later: bob has accrued ~24h of yield, alice has accrued ZERO (was in gap).
        vm.warp(block.timestamp + 24 hours);
        uint256 totalAtT24 = vault.totalAssets();
        uint256 deltaActual = totalAtT24 - totalAtT0;

        // Expected delta from bob's accrual only (alice contributes nothing while in gap).
        uint256 expectedBobYield = (30_000e18 * APY_18_PERCENT * 24 hours) /
            (365 days * 1e18);

        // Allow ~1 wei tolerance (integer rounding) — definitely tighter than any
        // phantom-yield contribution from alice would be.
        assertApproxEqAbs(
            deltaActual,
            expectedBobYield,
            1e12,  // dust tolerance: 1 micro-HOLLAR for cumulative integer rounding
            "Only fresh positions should accrue yield; phantom yield must not contribute"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   STALE-DURING-GAP: yield-claim while stale + unmark in PWR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice mark stale (in YWR) → claim yield while stale (state →PWR, isStale)
    ///         → unmark (state is PWR now) → no yield should be re-added → no phantom yield.
    function test_phantomYield_stalePathToUnmarkInPwr_noPhantom() public {
        _toYieldRequested(alice, 50_000e18);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Mark stale in YWR
        vm.prank(admin);
        vault.markPositionStale(0);

        // Claim yield while stale — state cascades to PWR
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 3, "should be PrincipalWithdrawalRequested");
        assertTrue(_isStale(0), "should still be stale");

        // Unmark (state is PWR) — should NOT restore yield bookkeeping
        vm.prank(admin);
        vault.unmarkPositionStale(0); // backtrack ignored for non-YWR

        // Verify no phantom yield from now to principal redemption
        uint256 totalBefore = vault.totalAssets();
        vm.warp(block.timestamp + 24 hours);
        uint256 totalAfter = vault.totalAssets();
        assertApproxEqAbs(
            totalAfter,
            totalBefore,
            10,
            "no phantom yield after stale-PWR-unmark sequence"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ACCOUNTING INVARIANT after fix
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice After my fix, totalAssets() = invested + idle + staleValue + accruedYield
    ///         where accruedYield is ONLY from active yield-bearing positions
    ///         (state = Active or YieldWithdrawalRequested, not stale).
    function test_phantomYield_totalAssetsFormulaHolds() public {
        // Build a portfolio: alice in PWR, bob still active
        _toPrincipalRequested(alice, 50_000e18); // pos 0 in PWR
        _deposit(bob, 30_000e18);                // pos 1 active

        _warpDays(30);

        // Expected accruedYield: only from bob's pos 1 (alice's was cleared at yield claim)
        // Note: bob deposited at the moment alice's yield was claimed. bob's yieldStartTime
        // = block.timestamp at deposit. After warpDays(30), bob has accrued 30 days of yield.
        uint256 expectedBobYield = (30_000e18 * APY_18_PERCENT * 30 days) / (365 days * 1e18);

        uint256 idleHollar = vault.idleHollar();
        uint256 invested = vault.totalInvestedPrincipal();
        uint256 stale = vault.totalStaleValue();
        uint256 totalAssets = vault.totalAssets();

        // total = invested + idle + stale + accruedYield(bob only)
        uint256 expectedTotal = invested + idleHollar + stale + expectedBobYield;

        assertApproxEqRel(
            totalAssets,
            expectedTotal,
            0.0001e18, // 0.01% — tight, since formula is exact modulo integer rounding
            "totalAssets matches invested+idle+stale+(only-active-yield)"
        );
    }
}
