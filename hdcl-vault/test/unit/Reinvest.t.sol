// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

contract ReinvestTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════
    //                    REINVEST INTO DECENTRAL
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_depositsIntoDecentral() public {
        // 1. Alice deposits -> position 0
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Warp past maturity and process position fully -> idle HOLLAR
        _warpDays(61);
        _processPositionFull(0);

        uint256 idleBefore = vault.idleHollar();
        assertGt(idleBefore, 0, "Should have idle HOLLAR after position processing");
        assertEq(vault.totalQueuedHdcl(), 0, "Queue should be empty");

        uint256 positionCountBefore = vault.getPositionCount();

        // 3. Reinvest
        vault.pokeQueue();

        // New position should be created
        uint256 positionCountAfter = vault.getPositionCount();
        assertEq(positionCountAfter, positionCountBefore + 1, "Should have one more position after reinvest");

        // idleHollar should decrease (to 0 since all idle was reinvested)
        uint256 idleAfter = vault.idleHollar();
        assertLt(idleAfter, idleBefore, "idleHollar should decrease after reinvest");

        // New position should have the reinvested amount as principal
        (, uint256 principal, , , , uint8 state) = vault.getPosition(positionCountBefore);
        assertApproxEqRel(
            principal,
            idleBefore,
            0.01e18,
            "New position principal should match idle HOLLAR"
        );
        assertEq(state, 0, "New position should be Active");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          REVERTS WHEN QUEUE NOT EMPTY
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_revertsQueueNotEmpty() public {
        // 1. Deposit and mature
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // 2. Alice requests redeem (queue is not empty)
        _requestRedeem(alice, aliceHdcl / 4);
        assertGt(vault.totalQueuedHdcl(), 0, "Queue should have entries");

        // 3. Reinvest should revert because queue is not empty
        vm.expectRevert(HDCLVault.QueueNotEmpty.selector);
        vault.pokeQueue();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //           REVERTS BELOW MIN AMOUNT
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_revertsBelowMinAmount() public {
        // 1. First deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Set minReinvestAmount high so small idle balances can't reinvest
        vm.prank(admin);
        vault.setMinReinvestAmount(100_000e18);

        // 3. Small deposit to idleHollar (below minReinvestAmount)
        //    We need idle HOLLAR but below the threshold.
        //    Process the position to get idle, but it won't be > 100k.
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 0, "Should have some idle");
        assertLt(idle, 100_000e18, "Idle should be less than minReinvestAmount");

        // 4. Reinvest should revert
        vm.expectRevert(HDCLVault.InsufficientIdleHollar.selector);
        vault.pokeQueue();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //            RESPECTS TVL CAP
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_respectsTvlCap() public {
        // 1. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Process position fully
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 0, "Should have idle HOLLAR");

        // 3. Set TVL cap to just above current invested (0) + small portion of idle
        //    After processing, totalInvestedPrincipal = 0, idle is principal + yield.
        //    Set cap to half of idle so reinvest is capped.
        uint256 halfIdle = idle / 2;
        vm.prank(admin);
        vault.setTvlCap(halfIdle);

        // 4. Reinvest -- should only reinvest up to TVL cap
        vault.pokeQueue();

        // New position principal should be capped at tvlCap
        (, uint256 principal, , , , ) = vault.getPosition(1);
        assertEq(principal, halfIdle, "Reinvested principal should be capped at TVL cap");

        // idle should still have remainder
        uint256 idleAfter = vault.idleHollar();
        assertApproxEqRel(
            idleAfter,
            idle - halfIdle,
            0.01e18,
            "Remaining idle should be idle minus capped reinvest amount"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //           UPDATES ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_updatesAccounting() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        uint256 investedBefore = vault.totalInvestedPrincipal();
        vault.pokeQueue();

        // totalInvestedPrincipal should increase by the reinvested amount
        uint256 investedAfter = vault.totalInvestedPrincipal();
        assertApproxEqRel(
            investedAfter,
            investedBefore + idle,
            0.01e18,
            "totalInvestedPrincipal should increase by reinvested amount"
        );

        // APY bucket should be updated (at least 1 active APY)
        assertGe(vault.getActiveAPYCount(), 1, "Should have at least 1 active APY after reinvest");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //        PRESERVES EXCHANGE RATE
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_preservesExchangeRate() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 rateBefore = vault.exchangeRate();

        vault.pokeQueue();

        uint256 rateAfter = vault.exchangeRate();

        // Exchange rate should be approximately preserved (idle moved to invested principal)
        assertApproxEqRel(
            rateAfter,
            rateBefore,
            0.01e18,
            "Exchange rate should be preserved after reinvest"
        );
    }
}
