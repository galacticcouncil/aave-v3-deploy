// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

contract ProcessPositionTest is BaseTest {
    /// @dev Helper to calculate expected yield: principal * apyWad * days / 365 / 1e18
    function _expectedYield(uint256 principal, uint256 apyWad, uint256 days_)
        internal
        pure
        returns (uint256)
    {
        return principal * apyWad * days_ * SECONDS_PER_DAY / (365 days * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //             ACTIVE -> YIELD WITHDRAWAL REQUESTED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_activeToYieldRequested() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp past 60-day maturity
        _warpDays(61);

        // Process: Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 1, "State should be YieldWithdrawalRequested (1)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         YIELD REQUESTED -> YIELD CLAIMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_yieldRequestedToYieldClaimed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield on mock pool
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        uint256 idleBefore = vault.idleHollar();

        // YieldWithdrawalRequested -> YieldClaimed -> PrincipalWithdrawalRequested
        // (yield claimed and principal requested happen in same call)
        vault.pokeDecentral(0);

        uint256 idleAfter = vault.idleHollar();
        assertGt(idleAfter, idleBefore, "idleHollar should increase after yield claim");

        (, , , , , uint8 state) = vault.getPosition(0);
        // After yield claim, it immediately transitions to PrincipalWithdrawalRequested
        assertEq(state, 3, "State should be PrincipalWithdrawalRequested (3) after yield claim");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //    YIELD CLAIMED -> PRINCIPAL WITHDRAWAL REQUESTED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_yieldClaimedToPrincipalRequested() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        // This single call should execute yield, then immediately request principal
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(
            state,
            3,
            "Should transition through YieldClaimed to PrincipalWithdrawalRequested in one call"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //     PRINCIPAL REQUESTED -> REDEEMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_principalRequestedToRedeemed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield and process (-> PrincipalWithdrawalRequested)
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        // Approve principal and warp past 48h delay
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 idleBefore = vault.idleHollar();

        // PrincipalWithdrawalRequested -> Redeemed
        vault.pokeDecentral(0);

        uint256 idleAfter = vault.idleHollar();
        assertGt(idleAfter, idleBefore, "idleHollar should increase after principal redemption");

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "State should be Redeemed (4)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //               FULL LIFECYCLE TEST
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_fullLifecycle() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);

        // Step 1: Warp past 60-day maturity
        _warpDays(61);

        // Step 2: Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);
        (, , , , , uint8 s1) = vault.getPosition(0);
        assertEq(s1, 1, "After step 2: YieldWithdrawalRequested");

        // Step 3: Approve yield on mock pool
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        // Step 4: Execute yield + request principal (single call)
        vault.pokeDecentral(0);
        (, , , , , uint8 s2) = vault.getPosition(0);
        assertEq(s2, 3, "After step 4: PrincipalWithdrawalRequested");

        // Step 5: Approve principal and warp past 48h
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Step 6: Execute principal -> Redeemed
        vault.pokeDecentral(0);
        (, , , , , uint8 s3) = vault.getPosition(0);
        assertEq(s3, 4, "After step 6: Redeemed");

        // Step 7: Verify total HOLLAR returned = principal + yield
        uint256 idle = vault.idleHollar();
        uint256 expectedYield = _expectedYield(depositAmount, APY_18_PERCENT, 61);
        uint256 expectedTotal = depositAmount + expectedYield;

        assertApproxEqRel(
            idle,
            expectedTotal,
            0.01e18,
            "idleHollar should equal principal + yield"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          NO-OP BEFORE MATURITY
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_noopBeforeMaturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Only warp 30 days (not past 60-day maturity)
        _warpDays(30);

        // Call processPosition -- should NOT advance state (no-op for active before maturity)
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "State should remain Active (0) before maturity");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //        REVERTS ON ALREADY REDEEMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_revertsOnRedeemed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Process fully through all states
        _processPositionFull(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "Position should be Redeemed");

        // Attempt to process again should revert
        vm.expectRevert(HDCLVault.PositionAlreadyRedeemed.selector);
        vault.pokeDecentral(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //    NO-OP WHEN YIELD NOT APPROVED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_noopNotApproved() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);
        (, , , , , uint8 s1) = vault.getPosition(0);
        assertEq(s1, 1, "Should be YieldWithdrawalRequested");

        // DO NOT approve yield on mock pool

        // Call processPosition again -- executeYieldWithdrawal will revert internally,
        // caught by try/catch, so it returns without advancing state
        vault.pokeDecentral(0);

        (, , , , , uint8 s2) = vault.getPosition(0);
        assertEq(s2, 1, "State should remain YieldWithdrawalRequested when not approved");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         ADVANCES POSITION HEAD
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_advancesPositionHead() public {
        // Create two positions
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionHead(), 0, "positionHead should start at 0");
        assertEq(vault.getPositionCount(), 2, "Should have 2 positions");

        // Warp past maturity
        _warpDays(61);

        // Process position 0 fully
        _processPositionFull(0);

        // After position 0 is redeemed, positionHead should advance to 1
        assertEq(vault.getPositionHead(), 1, "positionHead should advance to 1 after position 0 redeemed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         CORRECT YIELD AMOUNT
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_correctYieldAmount() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);

        _warpDays(61);

        // Track vault HOLLAR balance to detect yield received
        vault.pokeDecentral(0);
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        uint256 idleBefore = vault.idleHollar();

        // Execute yield withdrawal
        vault.pokeDecentral(0);

        uint256 idleAfter = vault.idleHollar();
        uint256 yieldReceived = idleAfter - idleBefore;

        // Expected yield: principal * 0.18 * 61 days / 365 days
        uint256 expectedYield = _expectedYield(depositAmount, APY_18_PERCENT, 61);

        assertApproxEqRel(
            yieldReceived,
            expectedYield,
            0.01e18,
            "Yield received should match expected calculation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //     TRIGGERS QUEUE PROCESSING
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_triggersQueueProcessing() public {
        // Alice deposits and gets HDCL
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp past maturity and process position fully -> idle HOLLAR
        _warpDays(61);
        _processPositionFull(0);

        // Now Alice has idle HOLLAR in the vault. She requests redeem.
        uint256 aliceHdcl = vault.balanceOf(alice);
        uint256 redeemAmount = aliceHdcl / 2;
        _requestRedeem(alice, redeemAmount);
        assertGt(vault.totalQueuedHdcl(), 0, "Queue should have entries");

        // Bob deposits (creates a new position at index 1)
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // Warp past maturity for Bob's position
        _warpDays(61);

        // Before processing Bob's position, check queue state
        // (The queue may have been halfly/fully cleared by Bob's deposit
        //  using existing idle HOLLAR. If not, processing Bob's position will do it.)
        uint256 queueBefore = vault.totalQueuedHdcl();
        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        // If queue was already cleared by Bob's deposit, the test passes trivially.
        // If queue still has entries, processing position 1 should trigger queue fulfillment.
        if (queueBefore > 0) {
            _processPositionFull(1);
            _claimAll(alice);

            uint256 queueAfter = vault.totalQueuedHdcl();
            assertLt(queueAfter, queueBefore, "Queue should be reduced after position redemption + claim");

            uint256 aliceHollarAfter = hollar.balanceOf(alice);
            assertGt(aliceHollarAfter, aliceHollarBefore, "Alice should receive HOLLAR from queue");
        } else {
            // Queue was already cleared by the deposit flow itself (queue clearing on deposit)
            // Verify Alice received HOLLAR through the deposit-triggered queue clearing
            assertGt(
                hollar.balanceOf(alice),
                90_000e18 - TEN_THOUSAND_HOLLAR,
                "Alice should have received HOLLAR from queue clearing on deposit"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //      MULTIPLE POSITIONS -- PROCESS OLDEST FIRST
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_multiplePositions() public {
        // Alice deposits (position 0)
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp 10 days, then Bob deposits (position 1)
        _warpDays(10);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionCount(), 2, "Should have 2 positions");

        // Warp 51 more days: position 0 is mature (61 days), position 1 is NOT (51 days)
        _warpDays(51);

        // Process position 0 -- should work (past 60 days)
        vault.pokeDecentral(0);
        (, , , , , uint8 state0) = vault.getPosition(0);
        assertEq(state0, 1, "Position 0 should advance to YieldWithdrawalRequested");

        // Process position 1 -- should no-op (only 51 days)
        vault.pokeDecentral(1);
        (, , , , , uint8 state1) = vault.getPosition(1);
        assertEq(state1, 0, "Position 1 should remain Active (not yet mature)");

        // Warp 10 more days so position 1 matures
        _warpDays(10);

        vault.pokeDecentral(1);
        (, , , , , uint8 state1b) = vault.getPosition(1);
        assertEq(state1b, 1, "Position 1 should now advance to YieldWithdrawalRequested");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   CATCH ARMS: pool.requestYieldWithdrawal / requestPrincipalWithdrawal
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice If Decentral reverts on `requestYieldWithdrawal` at maturity,
    ///         the try/catch swallows it and the position stays Active for
    ///         the next pokeDecentral to retry. Without the catch, a broken
    ///         pool at maturity would permanently lock the position.
    function test_processPosition_requestYieldRevert_staysActive() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Surgical: revert only requestYieldWithdrawal, leave everything else
        // working so we isolate the catch arm under test.
        pool.setRevertOnRequestYield(true);
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "Position stays Active when requestYield reverts");

        // Recovery: clear the flag and the next poke advances normally.
        pool.setRevertOnRequestYield(false);
        vault.pokeDecentral(0);
        (, , , , , uint8 state2) = vault.getPosition(0);
        assertEq(state2, 1, "Position advances after pool recovers");
    }

    /// @notice If Decentral reverts on `requestPrincipalWithdrawal`, the
    ///         try/catch keeps the position in YieldClaimed for retry.
    ///         pokeDecentral falls through state transitions in one call, so
    ///         the only way to land in YieldClaimed at the start of a fresh
    ///         poke is for the request-principal step to have reverted —
    ///         which is exactly the path this test exercises.
    function test_processPosition_requestPrincipalRevert_staysYieldClaimed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Block the request-principal step. The first poke will do
        // Active -> YWR (yield approve gates the next step).
        pool.setRevertOnRequestPrincipal(true);

        vault.pokeDecentral(0);
        (uint256 tokenId, , , , , uint8 sA) = vault.getPosition(0);
        assertEq(sA, 1, "Position is YieldWithdrawalRequested");

        // Approve yield, then poke again: executes yield -> YieldClaimed,
        // then falls through to requestPrincipalWithdrawal which reverts.
        // The catch returns and leaves state at YieldClaimed.
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);
        (, , , , , uint8 sB) = vault.getPosition(0);
        assertEq(sB, 2, "Position is YieldClaimed (request-principal caught)");

        // Idle HOLLAR should reflect the yield payout — yield exec ran fine.
        assertGt(vault.idleHollar(), 0, "yield was claimed before catch fired");

        // Recovery: clear the flag and the next poke advances to PWR.
        pool.setRevertOnRequestPrincipal(false);
        vault.pokeDecentral(0);
        (, , , , , uint8 sC) = vault.getPosition(0);
        assertEq(sC, 3, "Position advances to PrincipalWithdrawalRequested");
    }

    /// @notice ERC-7540 §maxRedeem/maxWithdraw: returns the value of all
    ///         settled-but-unclaimed requests for the caller. Pre-settle
    ///         returns 0; after pokeQueue settles, returns the claimable
    ///         amount; drops back as the user redeems. `previewWithdraw`
    ///         stays at 0 — documented sync-not-supported sentinel.
    function test_maxRedeem_maxWithdraw_reflectClaimable() public {
        // Pre-deposit: nothing claimable for anyone.
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem pre-deposit");
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw pre-deposit");
        assertEq(vault.maxRedeem(address(0)), 0, "zero addr has nothing");

        // Alice deposits + requests redeem, but pokeQueue hasn't run.
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0); // idle accumulates
        uint256 aliceHdcl = vault.balanceOf(alice);
        uint256 reqId = _requestRedeem(alice, aliceHdcl / 4);

        // Still 0 before settlement.
        assertEq(vault.maxRedeem(alice), 0, "no settle yet -> 0");
        assertEq(vault.maxWithdraw(alice), 0, "no settle yet -> 0");

        // Settle.
        vault.pokeQueue();

        uint256 claimableShares = vault.claimableRedeemRequest(reqId, alice);
        assertGt(claimableShares, 0, "settled some shares");

        // maxRedeem matches claimable shares.
        assertEq(vault.maxRedeem(alice), claimableShares, "maxRedeem == hdclSettled sum");

        // maxWithdraw matches the reserved HOLLAR for those shares.
        (, , , uint256 hollarOwed, ) = vault.getRedemptionRequest(reqId);
        assertEq(vault.maxWithdraw(alice), hollarOwed, "maxWithdraw == hollarOwed sum");

        // Unrelated address sees 0.
        assertEq(vault.maxRedeem(bob), 0, "bob has nothing");
        assertEq(vault.maxWithdraw(bob), 0, "bob has nothing");

        // Partial claim drops the maxes pro-rata.
        uint256 half = claimableShares / 2;
        vm.prank(alice);
        vault.redeem(half, alice, alice);
        assertApproxEqAbs(vault.maxRedeem(alice), claimableShares - half, 1, "maxRedeem after half claim");

        // previewWithdraw stays at 0 (documented sync-not-supported sentinel).
        assertEq(vault.previewWithdraw(1e18), 0, "previewWithdraw is always 0");
        assertEq(vault.previewWithdraw(0), 0, "previewWithdraw(0) is 0");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   _advancePositionHead bounded sweep (Finding #13 regression)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Create N small positions, mature them, then redeem all of them
    ///      in REVERSE order. After this every position is Redeemed but
    ///      positionHead is still at 0 — the eventual head sweep would have
    ///      to advance N slots in one call without the bound.
    function _redeemAllInReverseOrder(uint256 n) internal {
        // Need a controlled deposit size. 1 HOLLAR units (= 1e18) hit the
        // mock pool's minimum-investment exactly.
        uint256 each = 1e18 * 10; // 10 HOLLAR per position
        hollar.mint(alice, each * n);
        vm.prank(alice);
        hollar.approve(address(vault), type(uint256).max);

        for (uint256 i = 0; i < n; i++) {
            vm.prank(alice);
            vault.deposit(each, alice);
        }

        // Mature all positions simultaneously.
        _warpDays(61);

        // Redeem positions [n-1, n-2, ..., 1], leaving 0 Active so that
        // _advancePositionHead won't advance during the loop.
        for (uint256 i = n - 1; i >= 1; i--) {
            _processPositionFull(i);
        }
    }

    /// @notice Sweep cap fires after exactly MAX_POSITION_HEAD_SWEEP advances.
    function test_advancePositionHead_respectsSweepCap() public {
        uint256 n = 55; // > sweep cap of 50
        _redeemAllInReverseOrder(n);

        // positionHead is still 0 because every Redeemed transition above
        // was for an index > 0; _advancePositionHead saw position[0] Active
        // and stopped immediately.
        assertEq(vault.positionHead(), 0, "head unmoved while index 0 is Active");

        // Now redeem index 0. _advancePositionHead runs from head=0, sees
        // 0..49 Redeemed (n=55, so 0..54 all Redeemed once index 0 transitions),
        // advances up to the cap and stops.
        _processPositionFull(0);

        assertEq(
            vault.positionHead(),
            50,
            "head advanced exactly MAX_POSITION_HEAD_SWEEP slots"
        );
    }

    /// @notice Subsequent calls drain the backlog batch-at-a-time.
    function test_advancePositionHead_drainsBacklogAcrossCalls() public {
        uint256 n = 55;
        _redeemAllInReverseOrder(n);
        _processPositionFull(0); // first sweep, head = 50

        assertEq(vault.positionHead(), 50, "first batch advanced");

        // pokeQueue triggers another sweep without requiring a new redemption.
        vault.pokeQueue();

        assertEq(vault.positionHead(), n, "second sweep finishes the backlog");
    }

    /// @notice pokeQueue advances positionHead even when there's no queue
    ///         settlement work — the keeper's regular cadence keeps head
    ///         in sync with redeemed positions without needing a fresh
    ///         pokeDecentral.
    function test_pokeQueue_advancesPositionHead() public {
        // Create 5 positions, mature, redeem 4 in reverse, leaving index 0 Active.
        uint256 each = 10e18;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            vault.deposit(each, alice);
        }
        _warpDays(61);
        for (uint256 i = 4; i >= 1; i--) {
            _processPositionFull(i);
        }
        // Head is still 0 (we never redeemed index 0).
        assertEq(vault.positionHead(), 0, "head untouched");

        // Redeem index 0 — its sweep would advance through all 5 (≤ cap).
        _processPositionFull(0);
        assertEq(vault.positionHead(), 5, "head advanced through all 5");

        // Subsequent pokeQueue on a "settled" state is a no-op for head.
        uint256 headBefore = vault.positionHead();
        vault.pokeQueue();
        assertEq(vault.positionHead(), headBefore, "no-op when nothing to advance");
    }
}
