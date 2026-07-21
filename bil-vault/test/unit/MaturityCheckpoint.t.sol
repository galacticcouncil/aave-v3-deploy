// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

contract MaturityCheckpointTest is BaseTest {
    function test_heapOrdersOutOfOrderMaturitiesAndSyncsBounded() public {
        pool.setMinimumInvestmentPeriodSeconds(90 days);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 0, maturity 90d

        MockDecentralPool pool10 = _newPool(10 days);
        _activate(pool10);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 1, maturity 10d

        MockDecentralPool pool40 = _newPool(40 days);
        _activate(pool40);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 2, maturity 40d

        _warpDays(100);

        uint256 principal = 30_000e18;
        uint256 y10 = _yield(10 days);
        uint256 y40 = _yield(40 days);
        uint256 y90 = _yield(90 days);

        // Before stateful sync the oracle safely clamps every live rate to
        // the earliest root (10d).
        assertApproxEqAbs(
            vault.totalAssets(),
            principal + 3 * y10,
            3,
            "unsynced view clamps at 10d root"
        );

        assertEq(vault.syncMaturities(1), 1, "one root processed");
        assertApproxEqAbs(_pendingYield(1), y10, 1, "10d position is first heap root");
        assertEq(_pendingYield(0), 0, "90d position remains live");
        assertEq(_pendingYield(2), 0, "40d position remains live");
        assertApproxEqAbs(vault.totalPendingYield(), y10, 1, "10d position capped first");
        assertApproxEqAbs(
            vault.totalAssets(),
            principal + y10 + 2 * y40,
            3,
            "remaining live rates advance only to 40d root"
        );

        assertEq(vault.syncMaturities(1), 1, "second root processed");
        assertApproxEqAbs(_pendingYield(2), y40, 1, "40d position is second heap root");
        assertEq(_pendingYield(0), 0, "90d position remains live after two syncs");
        assertApproxEqAbs(vault.totalPendingYield(), y10 + y40, 2, "40d position capped second");
        assertApproxEqAbs(
            vault.totalAssets(),
            principal + y10 + y40 + y90,
            3,
            "90d root caps final live rate"
        );

        uint256 fullyCapped = vault.totalAssets();
        assertEq(vault.syncMaturities(1), 1, "third root processed");
        assertApproxEqAbs(_pendingYield(0), y90, 1, "90d position is final heap root");
        assertApproxEqAbs(vault.totalAssets(), fullyCapped, 1, "final sync is accounting-neutral");
        _warpDays(30);
        assertEq(vault.totalAssets(), fullyCapped, "time cannot move fully capped assets");
    }

    function test_rateSensitiveDepositRevertsUntilLargeBacklogIsDrained() public {
        // Seed idle HOLLAR first so the same backlog can exercise queue
        // settlement as well as deposit pricing.
        pool.setMinimumInvestmentPeriodSeconds(1 days);
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(1);
        _processPositionFull(0);
        assertGt(vault.idleHollar(), TEN_THOUSAND_HOLLAR);

        pool.setMinimumInvestmentPeriodSeconds(60 days);
        for (uint256 i = 0; i < 50; i++) {
            _deposit(alice, TEN_HOLLAR);
        }
        _deposit(bob, TEN_HOLLAR);
        _warpDays(60);

        uint256 countBefore = vault.getPositionCount();
        assertEq(vault.maxDeposit(bob), 0, "maxDeposit reports blocked backlog");
        assertEq(vault.maxMint(bob), 0, "maxMint reports blocked backlog");

        vm.expectRevert(BILVault.MaturityBacklog.selector);
        vm.prank(bob);
        vault.deposit(TEN_HOLLAR, bob);
        assertEq(vault.getPositionCount(), countBefore, "blocked deposit is atomic");

        vm.expectRevert(BILVault.MaturityBacklog.selector);
        vm.prank(bob);
        vault.mint(TEN_HOLLAR, bob);

        uint256 requestId = _requestRedeem(bob, vault.balanceOf(bob));
        vm.expectRevert(BILVault.MaturityBacklog.selector);
        vault.pokeQueue();
        (, , uint256 settledBefore, uint256 owedBefore, ,) = vault
            .getRedemptionRequest(requestId);
        assertEq(settledBefore, 0, "queue cannot lock a conservative rate");
        assertEq(owedBefore, 0, "no HOLLAR reserved while backlog remains");

        // Explicit checkpoints drain the bounded backlog before deposits can
        // resume, keeping maxDeposit and the actual deposit behavior aligned.
        assertEq(vault.syncMaturities(1), 1);
        vm.expectRevert(BILVault.MaturityBacklog.selector);
        vm.prank(charlie);
        vault.deposit(TEN_HOLLAR, charlie);
        assertEq(vault.syncMaturities(50), 50);
        _deposit(charlie, TEN_HOLLAR);
        assertEq(vault.getPositionCount(), countBefore + 1, "deposit resumes after backlog fits bound");

        vault.pokeQueue();
        (, , uint256 settledAfter, ,,) = vault.getRedemptionRequest(requestId);
        assertGt(settledAfter, 0, "queue resumes at the exact synchronized rate");
    }

    function test_zeroYieldMaturityIsCappedExactlyOnce() public {
        pool.setAPY(0);
        _deposit(alice, TEN_HOLLAR);
        _warpDays(60);

        assertEq(vault.syncMaturities(1), 1);
        assertEq(vault.totalPendingYield(), 0, "zero yield remains zero");
        assertEq(vault.syncMaturities(1), 0, "heap entry cannot be removed twice");
        assertEq(vault.totalPendingYield(), 0, "zero-yield sync is idempotent");
        vault.pokeDecentral(0);
        (, , , , , uint8 state,,,) = vault.getPosition(0);
        assertEq(state, 3, "zero-yield position advances to principal request");
    }

    function test_syncMaturitiesRemainsAvailableWhilePaused() public {
        _deposit(alice, TEN_HOLLAR);
        _warpDays(60);
        vm.prank(admin);
        vault.pause();

        assertEq(vault.syncMaturities(1), 1);
    }

    /// @notice Heap stress: eight positions created with scrambled maturities
    ///         must be checkpointed in ascending-maturity order across bounded
    ///         batches, each capped exactly once, with the live yield aggregate
    ///         fully drained at the end. Exercises repeated sift-down.
    function test_heapDrainsScrambledMaturitiesInOrder() public {
        // Deposit order -> period(days). Ascending maturity order is therefore
        // idx 3(10),1(20),5(30),7(40),0(50),4(60),6(70),2(80).
        uint16[8] memory periods = [uint16(50), 20, 80, 10, 60, 30, 70, 40];
        for (uint256 i = 0; i < 8; i++) {
            MockDecentralPool p = _newPool(uint256(periods[i]) * 1 days);
            _activate(p);
            _deposit(alice, TEN_THOUSAND_HOLLAR); // all at the same timestamp
        }

        _warpDays(90); // past the latest (80d) maturity; all due

        // Batch 1: the three earliest maturities (10d,20d,30d = idx 3,1,5).
        assertEq(vault.syncMaturities(3), 3, "batch 1 caps three");
        _assertCapped(3);
        _assertCapped(1);
        _assertCapped(5);
        _assertLive(7); // 40d not yet
        _assertLive(0); // 50d not yet

        // Batch 2: 40d,50d,60d = idx 7,0,4.
        assertEq(vault.syncMaturities(3), 3, "batch 2 caps three");
        _assertCapped(7);
        _assertCapped(0);
        _assertCapped(4);
        _assertLive(6); // 70d not yet
        _assertLive(2); // 80d not yet

        // Batch 3: 70d,80d = idx 6,2 (only two remain).
        assertEq(vault.syncMaturities(3), 2, "batch 3 caps the last two");
        _assertCapped(6);
        _assertCapped(2);

        // Every position capped exactly once => the live rate aggregate is
        // fully drained (no under/over-subtraction), and totalPendingYield is
        // the exact sum of each position's maturity-capped yield.
        assertEq(vault.yieldRateSum(), 0, "live yield aggregate fully drained");
        uint256 expected;
        for (uint256 i = 0; i < 8; i++) {
            expected += _yield(uint256(periods[i]) * 1 days);
        }
        assertApproxEqAbs(
            vault.totalPendingYield(),
            expected,
            8,
            "totalPendingYield equals the sum of capped yields"
        );

        // Fully capped: further time cannot move NAV, and sync is a no-op.
        uint256 assetsNow = vault.totalAssets();
        _warpDays(30);
        assertEq(vault.totalAssets(), assetsNow, "time cannot move fully capped assets");
        assertEq(vault.syncMaturities(8), 0, "nothing left to process");
    }

    /// @notice Heap re-ordering: a deposit made AFTER a partial drain, whose
    ///         maturity falls between already-capped and still-live positions,
    ///         must be checkpointed before the older-but-later-maturing one.
    ///         Exercises sift-up placing a fresh minimum at the root.
    function test_heapReordersInterleavedDeposit() public {
        MockDecentralPool p40 = _newPool(40 days);
        _activate(p40);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // idx 0, maturity t0+40d

        MockDecentralPool p60 = _newPool(60 days);
        _activate(p60);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // idx 1, maturity t0+60d

        _warpDays(45); // idx0 (40d) due; idx1 (60d) not
        assertEq(vault.syncMaturities(1), 1, "caps the 40d position");
        _assertCapped(0);
        _assertLive(1);

        // Interleave a new position maturing at t0+50d — EARLIER than idx1's
        // 60d. The heap must sift it above idx1.
        MockDecentralPool p5 = _newPool(5 days);
        _activate(p5);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // idx 2, maturity now(t0+45)+5 = t0+50d

        _warpDays(20); // now t0+65: both idx1(60d) and idx2(50d) are due

        // The next checkpoint must take idx2 (50d), NOT idx1 (60d), proving the
        // heap re-ordered after the interleaved insert.
        assertEq(vault.syncMaturities(1), 1, "one more capped");
        _assertCapped(2);
        _assertLive(1);

        assertEq(vault.syncMaturities(1), 1, "final capped");
        _assertCapped(1);
        assertEq(vault.yieldRateSum(), 0, "fully drained after interleave");
    }

    function _assertCapped(uint256 idx) internal view {
        (, , , , , , bool capped,,) = vault.getPosition(idx);
        assertTrue(capped, "position should be capped");
    }

    function _assertLive(uint256 idx) internal view {
        (, , , , , , bool capped,,) = vault.getPosition(idx);
        assertFalse(capped, "position should still be live");
    }

    function _newPool(uint256 period) internal returns (MockDecentralPool created) {
        MockPoolToken token = new MockPoolToken();
        created = new MockDecentralPool(address(hollar), address(token), APY_18_PERCENT);
        token.registerPool(address(created));
        created.setMinimumInvestmentPeriodSeconds(period);
        hollar.mint(address(created), 10_000_000e18);
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(created)));
    }

    function _activate(MockDecentralPool target) internal {
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(target)));
    }

    function _yield(uint256 elapsed) internal pure returns (uint256) {
        return (TEN_THOUSAND_HOLLAR * APY_18_PERCENT * elapsed) /
            (365 days * 1e18);
    }

    function _pendingYield(uint256 positionIndex) internal view returns (uint256 pending) {
        (, , , , , , , pending,) = vault.getPosition(positionIndex);
    }
}
