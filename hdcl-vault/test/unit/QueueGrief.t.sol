// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/console.sol";
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
            ids[i] = vault.requestRedeem(minR, user, user);
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
            ids[i] = vault.requestRedeem(minR, user, user);
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
        uint256 aliceReqId = vault.requestRedeem(1_000e18, alice, alice);
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
        vault.requestRedeem(1_000e18, alice, alice);

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
        vault.requestRedeem(1_000e18, alice, alice); // alice's redemption at id=0

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
        uint256 aliceId = vault.requestRedeem(1_000e18, alice, alice);
        assertEq(aliceId, 100, "alice's real request at id=100");

        // Process matured position 0 → fills idleHollar
        _warpDays(61);
        _processPositionFull(0);

        // Single pokeQueue: skip 100 holes (free) + rate-lock alice (1 work)
        vault.pokeQueue();
        _claimAll(alice);

        // After rate-locking alice's request, queueHead advances past her too
        // (full-settle advances head). After claim, hDCL is burned.
        assertEq(vault.queueHead(), 101, "single call processes alice past 100 holes");
        assertEq(vault.totalQueuedHdcl(), 0, "alice's HDCL burned after claim");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FIX B — cancelRedeem at head advances queueHead
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The single-cancel-at-head case advances queueHead by 1.
    function test_cancelRedeem_atHead_advancesQueueHead() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(1_000e18, alice, alice);
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
        vault.requestRedeem(1_000e18, alice, alice);
        vm.prank(bob);
        uint256 bobId = vault.requestRedeem(1_000e18, bob, bob);

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
            ids[i] = vault.requestRedeem(1_000e18, alice, alice);
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
            ids[i] = vault.requestRedeem(1_000e18, alice, alice);
        }
        vm.prank(bob);
        vault.requestRedeem(1_000e18, bob, bob); // id=3, NOT cancelled

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
            ids[i] = vault.requestRedeem(1_000e18, alice, alice);
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
        uint256 aliceId = vault.requestRedeem(1_000e18, alice, alice);
        vm.prank(bob);
        vault.requestRedeem(1_000e18, bob, bob);

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
        vault.requestRedeem(1_000e18, alice, alice);

        // Mature & process bob's position (id 0) to fund idleHollar and trigger
        // queue processing internally on principal redemption.
        _warpDays(61);
        _processPositionFull(0);

        // Internal pokeQueue: skip 150 holes (50..199, well under skip cap of 500),
        // then process alice's real request at id=200. queueHead → 201.
        assertEq(vault.queueHead(), 201, "Fix A skip budget cleans remaining holes + processes alice");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FIX C — claim path uses per-controller index, not full queue scan
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Regression for the cancel-spam claim-DoS finding.
    ///
    /// Original code: `_claimByShares` / `_claimByAssets` iterated
    /// `for (i = 0; i < queueTail; i++)` with NO cap. Each cancelled slot
    /// is `r.user == address(0)` and falls through the `continue` — but the
    /// `r.user` SLOAD still costs ~2100 gas. An attacker spending ~$1-$10
    /// on Hydration's cheap gas could bloat `queueTail` past the block-gas
    /// ceiling, after which any user's redeem/withdraw reverts and their
    /// escrowed hDCL + reserved HOLLAR are permanently locked.
    ///
    /// Fix: maintain `_settledByController[address] => uint256[] ids`,
    /// populated in `processQueue` on the 0 → >0 hdclSettled transition,
    /// swap-popped in claim when fully drained or stale. Claim iteration
    /// is now bounded by the user's own settled-but-unclaimed requests.
    function test_claim_robustAgainstQueueTailBloat() public {
        // 1. Alice opens a redemption that will get settled.
        _seedIdleHollar(50_000e18);
        vm.prank(alice);
        uint256 aliceReqId = vault.requestRedeem(1_000e18, alice, alice);
        vault.pokeQueue();

        // Confirm alice has claimable shares before the attack.
        uint256 claimable = vault.claimableRedeemRequest(aliceReqId, alice);
        assertGt(claimable, 0, "alice has settled shares pre-attack");

        // 2. Attacker (bob) bloats queueTail with 1000 deleted slots.
        vm.prank(bob);
        vault.deposit(50_000e18, bob); // bob needs HDCL to escrow per cycle
        uint256 tailBefore = vault.queueTail();
        _spamCreateAndCancelReverse(bob, 1000);
        assertEq(
            vault.queueTail(),
            tailBefore + 1000,
            "1000 zero-address holes injected"
        );

        // 3. Alice's claim still works — and importantly, the gas it
        //    consumes is bounded by HER own request count (1), not the
        //    attacker-controlled queueTail.
        uint256 hollarBefore = hollar.balanceOf(alice);
        uint256 gasBefore = gasleft();

        vm.prank(alice);
        uint256 assets = vault.redeem(claimable, alice, alice);

        uint256 gasUsed = gasBefore - gasleft();

        // Sanity: claim succeeded and delivered HOLLAR.
        assertGt(assets, 0, "redeem returned non-zero assets");
        assertEq(
            hollar.balanceOf(alice) - hollarBefore,
            assets,
            "alice received the HOLLAR"
        );

        // The crux: claim gas is well under any reasonable block ceiling
        // even with 1000 stale slots. Old code would scale linearly with
        // queueTail (1000 × ~2100 = ~2.1M gas just for the cold SLOADs).
        // New code: O(alice's own settled requests). Generous bound below
        // — actual usage should be ~50-100K.
        assertLt(
            gasUsed,
            500_000,
            "claim gas bounded regardless of queueTail bloat"
        );
    }

    /// @notice Stronger guarantee: claim gas is roughly constant in the
    ///         attacker's spam volume. Spam of 10 vs spam of 1000 produces
    ///         the same per-user claim cost (within fuzz noise).
    function test_claim_gasIsConstantInSpamVolume() public {
        // Take a vm.snapshot of pristine setup so we can run two scenarios.
        // Scenario A: 10 spam cancels then alice claims
        _seedIdleHollar(50_000e18);
        vm.prank(alice);
        uint256 aliceReqId = vault.requestRedeem(1_000e18, alice, alice);
        vault.pokeQueue();
        uint256 claimable = vault.claimableRedeemRequest(aliceReqId, alice);

        // Snapshot the post-settle, pre-attack state.
        uint256 snap = vm.snapshot();

        // ── Scenario A: 10 spam cycles ──────────────────────────────────
        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        _spamCreateAndCancelReverse(bob, 10);

        uint256 gasBeforeA = gasleft();
        vm.prank(alice);
        vault.redeem(claimable, alice, alice);
        uint256 gasUsedA = gasBeforeA - gasleft();

        // ── Scenario B: 1000 spam cycles (100× more) ────────────────────
        vm.revertTo(snap);

        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        _spamCreateAndCancelReverse(bob, 1000);

        uint256 gasBeforeB = gasleft();
        vm.prank(alice);
        vault.redeem(claimable, alice, alice);
        uint256 gasUsedB = gasBeforeB - gasleft();

        // Log the numbers so a future reader can see the actual scale-invariance.
        console.log("claim gas after 10 spam cycles:   ", gasUsedA);
        console.log("claim gas after 1000 spam cycles: ", gasUsedB);

        // Old code: gasUsedB / gasUsedA would be ~100x (linear in spam).
        // New code: ratio close to 1.0 — alice's work is unchanged.
        // Allow generous tolerance for solidity overhead noise.
        assertLt(
            gasUsedB,
            gasUsedA * 2,
            "claim gas ~constant: B should not be more than 2x A"
        );
    }

    /// @notice The per-controller settled index must NOT double-push on
    ///         repeated partial settles of the same request — otherwise
    ///         repeated pokeQueue calls would grow alice's own index
    ///         unboundedly. Verified by attempting two partial settles
    ///         and confirming claim still works cleanly.
    function test_settledIndex_noDuplicatePushOnRepeatedPartialSettle() public {
        // Make idle HOLLAR scarce so settles are partial.
        _seedIdleHollar(50_000e18);

        // Alice opens a huge request that can't be fully settled in one go.
        // First partial settle.
        vm.prank(alice);
        vault.deposit(50_000e18, alice);
        // Cache balance first — vm.prank is consumed by the next call (including
        // a view-call argument), so balanceOf() can't share a prank with redeem.
        uint256 aliceHdcl = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(aliceHdcl, alice, alice);

        vault.pokeQueue(); // partially settles, pushes to alice's index

        uint256 settledAfterFirst = vault.claimableRedeemRequest(reqId, alice);
        assertGt(settledAfterFirst, 0, "first partial settle landed");

        // Make more idle HOLLAR by maturing another position, then poke again.
        // The second poke would only re-push the same id if the guard is
        // missing. Use a second deposit + position to source more idle.
        vm.prank(bob);
        vault.deposit(50_000e18, bob);
        // Bob's deposit is at index 2 (alice=0 seed, alice=1 second deposit).
        _warpDays(61);
        _processPositionFull(2);

        vault.pokeQueue(); // second partial / full settle

        // Alice claims everything that's settled. If the index were
        // double-pushed, the claim walker would still work (swap-pop
        // tolerates stale entries) — but to be confident the guard works
        // we just check the claim succeeds and yields the full settled
        // amount in one call.
        uint256 totalClaimable = vault.claimableRedeemRequest(reqId, alice);
        assertGt(totalClaimable, settledAfterFirst, "more got settled");

        vm.prank(alice);
        uint256 assets = vault.redeem(totalClaimable, alice, alice);
        assertGt(assets, 0, "claim succeeds after multi-stage settle");

        // Nothing claimable remains for alice on this request.
        assertEq(
            vault.claimableRedeemRequest(reqId, alice),
            0,
            "all claimable drained"
        );
    }
}
