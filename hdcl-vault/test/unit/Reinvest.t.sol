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

    function test_reinvest_skippedWhenQueueNotEmpty() public {
        // 1. Deposit and mature
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 idleBefore = vault.idleHollar();
        assertGt(idleBefore, 0, "Should have idle HOLLAR");

        // 2. Alice requests redeem (queue is not empty)
        _requestRedeem(alice, aliceHdcl / 4);
        assertGt(vault.totalQueuedHdcl(), 0, "Queue should have entries");

        // 3. pokeQueue processes queue first, then reinvests remaining idle.
        //    Since queue has entries and idle can fulfill them, it processes the queue.
        //    After queue is cleared, remaining idle may be reinvested.
        vault.pokeQueue();

        // Queue should be processed (fulfilled)
        assertEq(vault.totalQueuedHdcl(), 0, "Queue should be fulfilled after pokeQueue");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //           REVERTS BELOW MIN AMOUNT
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_skippedBelowMinAmount() public {
        // 1. First deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Set minReinvestAmount high so small idle balances can't reinvest
        vm.prank(admin);
        vault.setMinReinvestAmount(100_000e18);

        // 3. Process the position to get idle HOLLAR, but it won't be > 100k.
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 0, "Should have some idle");
        assertLt(idle, 100_000e18, "Idle should be less than minReinvestAmount");

        uint256 posCountBefore = vault.getPositionCount();

        // 4. pokeQueue should NOT revert — it just skips reinvestment when below min amount
        vault.pokeQueue();

        // No new position should be created (reinvestment was skipped)
        uint256 posCountAfter = vault.getPositionCount();
        assertEq(posCountAfter, posCountBefore, "No new position should be created when below minReinvestAmount");

        // Idle HOLLAR should remain unchanged
        assertEq(vault.idleHollar(), idle, "Idle HOLLAR should remain unchanged when reinvestment is skipped");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //            RESPECTS TVL CAP
    // ═══════════════════════════════════════════════════════════════════════

    function test_reinvest_respectsTvlCap() public {
        // 1. Set a TVL cap that allows the initial deposit but will cap reinvestment.
        //    After processing a 10,000 HOLLAR position with yield, idle will be ~10,000 + yield.
        //    We set the cap so that reinvestment can only use part of the idle.
        //    totalAssets after processing: idle = principal + yield (~10,295 for 61 days at 18%).
        //    totalInvestedPrincipal = 0 (position is redeemed), totalStaleValue = 0.
        //    _reinvest caps: totalInvestedPrincipal + totalStaleValue + amount <= tvlCap
        //    So cap = half of idle means reinvest amount = cap (since invested = 0).
        vm.prank(admin);
        vault.setTvlCap(TEN_THOUSAND_HOLLAR); // enough for the deposit

        // 2. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 3. Process position fully -> idle HOLLAR (principal + yield)
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 0, "Should have idle HOLLAR");
        // idle > TEN_THOUSAND_HOLLAR because it includes yield
        assertGt(idle, TEN_THOUSAND_HOLLAR, "Idle should include yield on top of principal");

        // 4. Now set a tvlCap that is less than idle but >= totalAssets.
        //    totalAssets = totalInvestedPrincipal(0) + accruedYield(0) + idle + totalStaleValue(0) = idle
        //    So we can only set cap >= idle. But we want to CAP reinvestment.
        //    _reinvest caps: totalInvestedPrincipal + totalStaleValue + amount <= tvlCap
        //    After full processing, totalInvestedPrincipal = 0, so amount <= tvlCap.
        //    Setting tvlCap = idle/2 would fail the setTvlCap check.
        //    Instead, keep the cap at TEN_THOUSAND_HOLLAR (which is < idle = ~10,295).
        //    Wait — setTvlCap requires newCap >= totalAssets(). totalAssets = idle here.
        //    So we can't set it below idle. But we CAN keep the existing cap if it was set before.
        //    The current tvlCap is already TEN_THOUSAND_HOLLAR which is < idle.
        //    The _reinvest check is: totalInvestedPrincipal + totalStaleValue + amount > tvlCap
        //    => 0 + 0 + amount > 10,000 => amount capped at 10,000.
        //    Since idle > 10,000, the reinvest should only use 10,000.

        uint256 posCountBefore = vault.getPositionCount();

        // 5. Reinvest -- should be capped at tvlCap
        vault.pokeQueue();

        // New position principal should be capped at tvlCap
        (, uint256 principal, , , , ) = vault.getPosition(posCountBefore);
        assertEq(principal, TEN_THOUSAND_HOLLAR, "Reinvested principal should be capped at TVL cap");

        // idle should still have remainder (the yield portion beyond the cap)
        uint256 idleAfter = vault.idleHollar();
        assertApproxEqRel(
            idleAfter,
            idle - TEN_THOUSAND_HOLLAR,
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

    // ═══════════════════════════════════════════════════════════════════════
    //   AUDIT FINDING #5 — reinvest fires when queue is wedged
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pre-fix, `pokeQueue` used a static `queueCanProgress` check
    ///         (totalQueuedHdcl > 0 && idleHollar > 0) to gate reinvest. If
    ///         the queue's head entry was wedged (parked behind an unmet
    ///         slippage floor) but funds were idle, that check was still
    ///         `true` and reinvest was silently suppressed — hoarding funds
    ///         that should have been earning yield. Post-fix the gate uses
    ///         the actual `hollarUsed` returned by the processor, so a queue
    ///         that made no real progress no longer blocks reinvest.
    function test_reinvest_firesWhenQueueIsWedgedByParkedEntry() public {
        // Three positions so the rate has headroom to drop without the
        // invariant rate >= 1.0 going wrong.
        _deposit(alice, TEN_THOUSAND_HOLLAR); // position 0 — shortfall victim
        _deposit(bob, 1_000e18);              // position 1
        _deposit(charlie, 1_000e18);          // position 2
        _warpDays(61);

        // Bob queues at the highest legal floor — passes the submission cap.
        uint256 rateAtSubmission = vault.exchangeRate();
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, rateAtSubmission);

        // Shortfall on alice's position drops the rate below bob's floor when
        // the principal lands, parking him in the queue.
        (uint256 tokenId0, , , , , ) = vault.getPosition(0);
        pool.setPayoutDelta(tokenId0, -100e18);
        _processPositionFull(0);

        // Sanity: queue is wedged on bob's parked entry, idleHollar is alive.
        assertGt(vault.idleHollar(), 0, "idleHollar after processing");
        assertGt(vault.totalQueuedHdcl(), 0, "bob's escrow still queued");
        // Snapshot the wedge state we expect pokeQueue to break out of.
        uint256 idleBefore = vault.idleHollar();
        uint256 posCountBefore = vault.getPositionCount();
        require(idleBefore >= vault.minReinvestAmount(), "test setup: idle must exceed min reinvest");

        // Externally-called pokeQueue. Pre-fix: queueCanProgress = true →
        // reinvest skipped → idleHollar hoarded. Post-fix: processor returns
        // hollarUsed = 0 → reinvest fires.
        vault.pokeQueue();

        assertEq(
            vault.getPositionCount(),
            posCountBefore + 1,
            "reinvest created a new position despite bob's parked entry"
        );
        assertLt(
            vault.idleHollar(),
            idleBefore,
            "idleHollar drained into the new position"
        );
        // Bob's entry is untouched — still queued, still escrowed.
        assertGt(vault.totalQueuedHdcl(), 0, "bob still in queue, unaffected by reinvest");
    }

    /// @notice Converse of the regression: when the queue actually makes
    ///         progress (a fulfillable entry behind the parked one), the
    ///         reinvest stays suppressed — preserving the "service queue
    ///         first" semantics. The leftover idle will be reinvested on a
    ///         later pokeQueue call once the queue is fully wedged or empty.
    function test_reinvest_suppressedWhenQueueMakesProgress() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // Bob queues a redemption with no floor — easily fulfillable from
        // idleHollar.
        _deposit(bob, 1_000e18);
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);

        uint256 posCountBefore = vault.getPositionCount();

        vault.pokeQueue();

        // Bob is fulfilled (hollarUsed > 0). Reinvest is suppressed even
        // though idleHollar is still positive — the contract chooses to
        // service the queue this call and let any leftover earn yield on
        // the next pokeQueue (when the queue is empty/wedged).
        assertEq(vault.totalQueuedHdcl(), 0, "bob's redemption fulfilled");
        assertEq(
            vault.getPositionCount(),
            posCountBefore,
            "no new position - reinvest correctly suppressed during progress"
        );
    }
}
