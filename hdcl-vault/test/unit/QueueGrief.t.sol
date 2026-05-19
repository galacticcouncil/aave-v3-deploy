// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title Redemption Queue Grief Vector — Regression Coverage
/// @notice Verifies that mass create-then-cancel attacks cannot starve legitimate
///         redemptions of pokeQueue's iteration budget. Two complementary fixes:
///           Fix A — `_processQueueWithHollar` doesn't count zero-address skips
///                   against the work iteration cap (separate skip cap).
///           Fix B — `cancelRedeem` advances queueHead past consecutive cancelled
///                   slots when cancelling at the head (capped sweep).
contract QueueGriefTest is BaseTest {
    // Larger user balances so we can simulate hundreds of redemption requests.
    function setUp() public override {
        super.setUp();
        // Top up alice & bob with extra HOLLAR for many small redemption requests.
        // Each requestRedeem locks `minRedeemAmount = 1e18` HDCL, recovered on cancel.
        hollar.mint(alice, 1_000_000e18);
        hollar.mint(bob, 1_000_000e18);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _depositForRedemption(address user, uint256 amount) internal {
        vm.prank(user);
        vault.deposit(amount, user);
    }

    /// @dev Spam N requestRedeem then cancel each, leaving N zero-address slots
    /// at queue positions [startId, startId+N). Caller must already hold HDCL.
    function _spamCreateAndCancelInOrder(address user, uint256 n) internal {
        uint256 minR = vault.minRedeemAmount();
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(user);
            ids[i] = vault.requestRedeem(minR);
        }
        for (uint256 i = 0; i < n; i++) {
            vm.prank(user);
            vault.cancelRedeem(ids[i]);
        }
    }

    /// @dev Same but cancel in REVERSE order so head-sweep doesn't trigger.
    function _spamCreateAndCancelReverse(address user, uint256 n) internal {
        uint256 minR = vault.minRedeemAmount();
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(user);
            ids[i] = vault.requestRedeem(minR);
        }
        for (uint256 i = n; i > 0; i--) {
            vm.prank(user);
            vault.cancelRedeem(ids[i - 1]);
        }
    }

    /// @dev Standard setup: alice deposits, position matures, processes through
    /// to Redeemed → idleHollar holds principal + yield.
    function _seedIdleHollar(uint256 depositAmount) internal {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        _warpDays(61);
        _processPositionFull(0);
        // After this, vault.idleHollar() > 0 with principal + ~30% of a year's yield
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FIX A — pokeQueue doesn't burn budget on zero-addr skips
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Regression: a wave of cancelled requests in front of a real one
    ///         used to delay processing by ceil(N/50) calls. With Fix A, a single
    ///         pokeQueue call can skip past them up to MAX_QUEUE_SKIPS=500 holes
    ///         while still doing real work.
    function test_grief_cancelSpamMidQueueDoesNotStarveRealRequest() public {
        // Seed a real request from alice. Note: id=0 is alice's redemption.
        vm.prank(alice);
        vault.deposit(50_000e18, alice);

        vm.prank(alice);
        uint256 aliceReqId = vault.requestRedeem(1_000e18);
        assertEq(aliceReqId, 0, "alice's request at id=0");

        // Bob spams 200 mid-queue cancellations (cancel in reverse so Fix B's
        // head-sweep doesn't reach them — these are pure mid-queue holes).
        vm.prank(bob);
        vault.deposit(50_000e18, bob); // bob needs HDCL to escrow
        _spamCreateAndCancelReverse(bob, 200);

        assertEq(vault.queueHead(), 0, "queueHead unchanged (none were at head)");
        assertEq(vault.getRedemptionQueueLength(), 201, "201 total slots");

        // Now mature alice's deposit and process to fill idleHollar.
        _warpDays(61);
        _processPositionFull(0);

        // One pokeQueue call must:
        //   1. Fulfill alice's request (id=0) — 1 work iteration
        //   2. Sweep through ALL 200 holes (id=1..200) — within the 500-skip cap
        // Without Fix A, only 50 iterations total → can't reach end of queue.
        vault.pokeQueue();

        assertEq(
            vault.queueHead(),
            201,
            "single pokeQueue should advance head past all holes"
        );
    }

    /// @notice Even larger grief: 500 holes (exactly the skip cap) — still single call.
    function test_grief_cancelSpam500HolesSingleCall() public {
        // Seed alice's real request at id=0
        vm.prank(alice);
        vault.deposit(50_000e18, alice);
        vm.prank(alice);
        vault.requestRedeem(1_000e18);

        // Bob makes 500 mid-queue holes
        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        _spamCreateAndCancelReverse(bob, 500);

        _warpDays(61);
        _processPositionFull(0);

        vault.pokeQueue();
        assertEq(
            vault.queueHead(),
            501,
            "single pokeQueue should advance through exactly MAX_QUEUE_SKIPS holes after fulfilling alice"
        );
    }

    /// @notice Grief past the skip cap: each pokeQueue call (including the one
    ///         triggered internally by principal redemption) advances by at most
    ///         work + MAX_QUEUE_SKIPS. The cap protects against gas exhaustion
    ///         while preserving liveness — multiple calls fully clear the queue.
    function test_grief_cancelSpamAboveSkipCapStillProgresses() public {
        vm.prank(alice);
        vault.deposit(50_000e18, alice);
        vm.prank(alice);
        vault.requestRedeem(1_000e18); // alice's redemption at id=0

        // Bob makes 700 mid-queue holes (above MAX_QUEUE_SKIPS=500)
        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        _spamCreateAndCancelReverse(bob, 700); // ids 1..700; queueHead stays 0

        assertEq(vault.queueHead(), 0, "queueHead at alice's request");

        _warpDays(61);
        // Processing position 0 (alice's deposit) triggers an internal pokeQueue
        // call after principal redemption. That call:
        //   - processes alice's redemption (1 work iteration)
        //   - sweeps MAX_QUEUE_SKIPS=500 holes, then hits the cap
        // queueHead lands at 501 (1 fulfillment + 500 skips).
        _processPositionFull(0);
        assertEq(vault.queueHead(), 501, "internal pokeQueue: alice + skip cap");

        // A second pokeQueue call sweeps the remaining 200 holes (no real work).
        vault.pokeQueue();
        assertEq(vault.queueHead(), 701, "explicit call sweeps remaining 200 holes");
    }

    /// @notice The pre-fix attack: 100 zero-addr slots in front of a real one.
    ///         Pre-fix this took 3 calls (50, 50, then process). Post-fix: 1 call.
    function test_grief_pokeQueueProcessesRealAfterMidQueueHoles() public {
        // Bob makes 100 mid-queue holes
        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        _spamCreateAndCancelReverse(bob, 100);

        // Now alice creates a real request at id=100
        vm.prank(alice);
        vault.deposit(50_000e18, alice);
        vm.prank(alice);
        uint256 aliceId = vault.requestRedeem(1_000e18);
        assertEq(aliceId, 100, "alice's real request at id=100");

        // Process matured position 0 → fills idleHollar
        _warpDays(61);
        _processPositionFull(0);

        // Single pokeQueue: skip 100 holes (free) + fulfill alice (1 work)
        vault.pokeQueue();

        // After processing alice (full fulfillment), head should be at 101
        assertEq(vault.queueHead(), 101, "single call processes alice past 100 holes");
        assertEq(vault.totalQueuedHdcl(), 0, "alice's HDCL burned");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FIX B — cancelRedeem at head advances queueHead
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The single-cancel-at-head case advances queueHead by 1.
    function test_cancelRedeem_atHead_advancesQueueHead() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(1_000e18);
        assertEq(vault.queueHead(), 0);
        assertEq(vault.queueTail(), 1);

        vm.prank(alice);
        vault.cancelRedeem(reqId);

        assertEq(vault.queueHead(), 1, "queueHead advanced past cancelled head");
        assertEq(vault.queueTail(), 1, "queueTail unchanged");
    }

    /// @notice Cancelling NOT at head leaves queueHead untouched (the slot stays
    ///         as a mid-queue hole; pokeQueue's Fix A handles it).
    function test_cancelRedeem_notAtHead_keepsQueueHead() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);
        vm.prank(bob);
        vault.deposit(10_000e18, bob);

        // alice creates id=0, bob creates id=1
        vm.prank(alice);
        vault.requestRedeem(1_000e18);
        vm.prank(bob);
        uint256 bobId = vault.requestRedeem(1_000e18);

        assertEq(vault.queueHead(), 0);
        assertEq(vault.queueTail(), 2);

        // Bob cancels his own (id=1, NOT at head)
        vm.prank(bob);
        vault.cancelRedeem(bobId);

        assertEq(vault.queueHead(), 0, "queueHead unchanged when cancelling non-head");
    }

    /// @notice When cancelling at head with consecutive cancelled slots after,
    ///         the sweep advances queueHead through all of them in one shot
    ///         (capped at MAX_QUEUE_ITERATIONS).
    function test_cancelRedeem_sweepsConsecutiveHoles() public {
        vm.prank(alice);
        vault.deposit(50_000e18, alice);

        // Alice creates 5 requests, all owned by her
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            ids[i] = vault.requestRedeem(1_000e18);
        }

        assertEq(vault.queueHead(), 0);
        assertEq(vault.queueTail(), 5);

        // Cancel ids 1, 2, 3, 4 first (none at head — head=0 throughout)
        for (uint256 i = 1; i < 5; i++) {
            vm.prank(alice);
            vault.cancelRedeem(ids[i]);
        }
        assertEq(vault.queueHead(), 0, "head still at 0 after non-head cancels");

        // Now cancel id=0. Sweep should advance head through 0, 1, 2, 3, 4 → 5.
        vm.prank(alice);
        vault.cancelRedeem(ids[0]);

        assertEq(vault.queueHead(), 5, "head swept through all 5 consecutive holes");
        assertEq(vault.queueTail(), 5, "queue effectively empty");
    }

    /// @notice Sweep stops at the first non-zero slot, not at queueTail.
    function test_cancelRedeem_sweepStopsAtRealRequest() public {
        vm.prank(alice);
        vault.deposit(50_000e18, alice);
        vm.prank(bob);
        vault.deposit(10_000e18, bob);

        // alice: ids 0, 1, 2 (will all be cancelled). bob: id 3 (real, kept).
        uint256[] memory ids = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            ids[i] = vault.requestRedeem(1_000e18);
        }
        vm.prank(bob);
        vault.requestRedeem(1_000e18); // id=3, NOT cancelled

        // Cancel alice's 1 and 2 first (mid-queue, no sweep)
        vm.prank(alice);
        vault.cancelRedeem(ids[1]);
        vm.prank(alice);
        vault.cancelRedeem(ids[2]);
        assertEq(vault.queueHead(), 0);

        // Now cancel alice's id=0 (head). Sweep advances through 0, 1, 2 but
        // stops at 3 (bob's real request).
        vm.prank(alice);
        vault.cancelRedeem(ids[0]);

        assertEq(vault.queueHead(), 3, "sweep stops at bob's request");
        assertEq(vault.queueTail(), 4, "queue still has bob's request");
    }

    /// @notice Sweep is bounded at MAX_QUEUE_ITERATIONS (50) per cancel call.
    ///         If more than 50 consecutive holes exist, only the first 50 are
    ///         consumed; the rest are left to pokeQueue's skip budget.
    function test_cancelRedeem_sweepCappedAtMaxIterations() public {
        // Alice creates 60 requests
        vm.prank(alice);
        vault.deposit(100_000e18, alice);

        uint256[] memory ids = new uint256[](60);
        for (uint256 i = 0; i < 60; i++) {
            vm.prank(alice);
            ids[i] = vault.requestRedeem(1_000e18);
        }

        // Cancel ids 1..59 first (mid-queue, no sweep)
        for (uint256 i = 1; i < 60; i++) {
            vm.prank(alice);
            vault.cancelRedeem(ids[i]);
        }
        assertEq(vault.queueHead(), 0);

        // Now cancel id=0 (head). Sweep advances through 0, 1, ..., 49 only
        // (capped at 50 = MAX_QUEUE_ITERATIONS).
        vm.prank(alice);
        vault.cancelRedeem(ids[0]);

        assertEq(
            vault.queueHead(),
            50,
            "sweep capped at MAX_QUEUE_ITERATIONS (50) advances"
        );

        // Slots 50..59 are still zero-addr; queueTail = 60.
        assertEq(vault.queueTail(), 60, "queueTail unchanged");
    }

    /// @notice Single cancel-at-head with no other holes advances queueHead by exactly 1.
    function test_cancelRedeem_atHeadNoConsecutive_singleAdvance() public {
        vm.prank(alice);
        vault.deposit(20_000e18, alice);
        vm.prank(bob);
        vault.deposit(20_000e18, bob);

        // alice id=0, bob id=1
        vm.prank(alice);
        uint256 aliceId = vault.requestRedeem(1_000e18);
        vm.prank(bob);
        vault.requestRedeem(1_000e18);

        // alice cancels her own (head). Bob's slot is non-zero → sweep stops at 1.
        vm.prank(alice);
        vault.cancelRedeem(aliceId);

        assertEq(vault.queueHead(), 1, "single advance, bob's slot is real");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   COMBINED — Fix A + Fix B together neutralize the grief
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sequential cancel-from-head spam: every cancel auto-advances head
    ///         (via Fix B's single-step), so by the end the queue is empty even
    ///         without any pokeQueue calls.
    function test_combined_sequentialCancelFromHeadAutoCleansQueue() public {
        vm.prank(alice);
        vault.deposit(100_000e18, alice);

        // Spam 100 create+cancel in IN-ORDER (each cancel-at-head auto-advances)
        _spamCreateAndCancelInOrder(alice, 100);

        assertEq(vault.queueHead(), 100, "head fully advanced via cancel-at-head");
        assertEq(vault.queueTail(), 100, "queue empty");
        assertEq(vault.totalQueuedHdcl(), 0, "no escrow");
    }

    /// @notice Worst-case adversarial: attacker uses reverse-order cancels.
    ///         The LAST reverse cancel (lowest id, in this test bob's id=0) is
    ///         at head, so Fix B's capped sweep kicks in. The remaining holes
    ///         (above the cap) are cleaned by Fix A's skip budget in pokeQueue.
    function test_combined_reverseOrderCancelsCleanedByPokeQueue() public {
        // Bob is the only depositor so far — his first request is id=0.
        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        _spamCreateAndCancelReverse(bob, 200);

        // The last reverse cancel is bob's id=0, which IS at queueHead.
        // Fix B sweeps MAX_QUEUE_ITERATIONS=50 zero-addr slots → queueHead=50.
        assertEq(vault.queueHead(), 50, "Fix B sweep on the at-head cancel");
        assertEq(vault.queueTail(), 200, "200 total slots created");

        // Alice creates real request at id=200
        vm.prank(alice);
        vault.deposit(50_000e18, alice);
        vm.prank(alice);
        vault.requestRedeem(1_000e18);

        // Mature & process bob's position (id 0) to fund idleHollar and trigger
        // queue processing internally on principal redemption.
        _warpDays(61);
        _processPositionFull(0);

        // Internal pokeQueue: skip 150 holes (50..199, well under skip cap of 500),
        // then process alice's real request at id=200. queueHead → 201.
        assertEq(vault.queueHead(), 201, "Fix A skip budget cleans remaining holes + processes alice");
    }
}
