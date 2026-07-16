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
        assertEq(vault.syncMaturities(1), 0, "heap entry cannot be removed twice");
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
