// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

contract MaturityCheckpointTest is BaseTest {
    /// @notice The FIFO clamp relies on positions being appended in
    ///         non-decreasing maturity order. A deposit into a shorter-period
    ///         pool while an older, longer-maturity position is still live must
    ///         revert rather than silently corrupt the checkpointHead ordering.
    function test_outOfOrderMaturityDepositReverts() public {
        pool.setMinimumInvestmentPeriodSeconds(90 days);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 0, maturity now+90d

        // Switch to a 10-day pool: a new position would mature BEFORE index 0.
        MockDecentralPool pool10 = _newPool(10 days);
        _activate(pool10);
        vm.expectRevert(BILVault.NonMonotonicMaturity.selector);
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    /// @notice With in-order (constant-period) maturities, the unsynced view
    ///         clamps at the earliest un-checkpointed maturity, `syncMaturities`
    ///         advances the head one position per unit, and once fully drained
    ///         `totalAssets` is time-invariant.
    function test_inOrderMaturitiesClampAndBoundedSync() public {
        // Three staggered deposits into the default 60-day pool → maturities
        // are strictly increasing (t0+60, t5+60, t10+60), so FIFO holds.
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 0
        _warpDays(5);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 1
        _warpDays(5);
        _deposit(alice, TEN_THOUSAND_HOLLAR); // index 2

        // Warp well past all three maturities without any sync.
        _warpDays(120);

        // Unsynced accounting is frozen at the earliest maturity: advancing
        // time cannot inflate it (the H-01 guarantee, keeper-free).
        uint256 clampedAssets = vault.totalAssets();
        _warpDays(30);
        assertEq(vault.totalAssets(), clampedAssets, "unsynced view is time-frozen");

        // Bounded sync advances one position per unit, in order.
        assertEq(vault.checkpointHead(), 0, "nothing checkpointed yet");
        assertEq(vault.syncMaturities(1), 1, "one processed");
        assertEq(vault.checkpointHead(), 1, "head advanced by one");
        assertGt(_pendingYield(0), 0, "index 0 capped");
        assertEq(_pendingYield(1), 0, "index 1 still live");

        // Drain the rest; NAV rises (conservative under-count corrects upward)
        // then becomes time-invariant once fully checkpointed.
        assertEq(vault.syncMaturities(50), 2, "remaining two processed");
        assertEq(vault.checkpointHead(), 3, "all checkpointed");
        assertGe(vault.totalAssets(), clampedAssets, "sync corrects upward, never down");

        uint256 fullyCapped = vault.totalAssets();
        _warpDays(30);
        assertEq(vault.totalAssets(), fullyCapped, "time cannot move fully capped assets");
        assertEq(vault.syncMaturities(1), 0, "nothing left to process");
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
        (, , uint256 settledBefore, uint256 owedBefore, ) = vault
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
        (, , uint256 settledAfter, , ) = vault.getRedemptionRequest(requestId);
        assertGt(settledAfter, 0, "queue resumes at the exact synchronized rate");
    }

    function test_zeroYieldMaturityIsCappedExactlyOnce() public {
        pool.setAPY(0);
        _deposit(alice, TEN_HOLLAR);
        _warpDays(60);

        assertEq(vault.syncMaturities(1), 1);
        assertEq(vault.totalPendingYield(), 0, "zero yield remains zero");
        assertEq(vault.syncMaturities(1), 0, "position cannot be checkpointed twice");
        assertEq(vault.totalPendingYield(), 0, "zero-yield sync is idempotent");
        vault.pokeDecentral(0);
        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 3, "zero-yield position advances to principal request");
    }

    function test_syncMaturitiesRemainsAvailableWhilePaused() public {
        _deposit(alice, TEN_HOLLAR);
        _warpDays(60);
        vm.prank(admin);
        vault.pause();

        assertEq(vault.syncMaturities(1), 1);
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
        (, , , , , , , , pending) = vault.positions(positionIndex);
    }
}
