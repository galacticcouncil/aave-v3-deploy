// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title Redemption Slippage Protection & Parking Behavior
/// @notice Two-part design for the requestRedeem slippage floor:
///   1. Submission cap — `minRateWad` must be ≤ exchangeRate() at submission.
///      A floor strictly above the current rate is unreachable by construction
///      (a redeemer cannot command the rate upward) and pre-fix could be used
///      to permanently brick the redemption queue. Now rejected at the door.
///   2. Park-and-skip — at fulfillment, an entry whose floor is below the
///      current rate is *parked* in place (not removed, not refunded). The
///      processor scans past it to serve subsequent entries, and the parked
///      entry re-evaluates against the rate on every future call. This
///      eliminates the head-of-line block while preserving the user's queue
///      position so they don't have to resubmit when the rate dips briefly.
contract RequestRedeemSlippageTest is BaseTest {
    /// @dev Standard seed used by the satisfied/zero-floor tests: alice's
    ///      deposit matures into idleHollar.
    function _seedIdle(address user, uint256 amount) internal {
        _deposit(user, amount);
        _warpDays(61);
        _processPositionFull(0);
    }

    /// @dev Build the parking-test setup: alice supplies the position that
    ///      will be paid with a shortfall (to drop the rate), bob & charlie
    ///      hold HDCL ready to submit redemption requests. Returns the
    ///      pre-shortfall rate so callers can use it as the slippage floor.
    function _setupForRateDrop()
        internal
        returns (uint256 rateAtSubmission)
    {
        _deposit(alice, TEN_THOUSAND_HOLLAR); // position 0 — shortfall victim
        _deposit(bob, 1_000e18);              // position 1
        _deposit(charlie, 1_000e18);          // position 2
        _warpDays(61);
        rateAtSubmission = vault.exchangeRate();
    }

    /// @dev Apply a negative payout delta to position 0 so that processing it
    ///      lands a smaller-than-expected principal payment, lowering the
    ///      exchange rate via the PrincipalMismatch path.
    function _scheduleShortfall(uint256 shortfallHollar) internal {
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.setPayoutDelta(tokenId, -int256(shortfallHollar));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   SATISFIED — rate at/above floor → fulfilled
    // ═══════════════════════════════════════════════════════════════════════

    function test_requestRedeemSlippage_satisfied_fulfills() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 currentRate = vault.exchangeRate();
        uint256 floor = (currentRate * 99) / 100; // 1% below current

        uint256 bobHdclLocal = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdclLocal, floor);

        uint256 bobBefore = hollar.balanceOf(bob);
        vault.pokeQueue();

        assertGt(hollar.balanceOf(bob), bobBefore, "bob got HOLLAR - rate satisfied floor");
    }

    function test_requestRedeemSlippage_zeroFloor_alwaysFulfills() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);

        uint256 bobBefore = hollar.balanceOf(bob);
        vault.pokeQueue();
        assertGt(hollar.balanceOf(bob), bobBefore, "zero floor = no slippage check");
    }

    function test_requestRedeem_legacyNoFloor() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);

        uint256 bobBefore = hollar.balanceOf(bob);
        vault.pokeQueue();
        assertGt(hollar.balanceOf(bob), bobBefore, "no-floor requestRedeem fulfills");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   SUBMISSION CAP — floor above current rate rejected at the door
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A floor strictly above the current rate is unreachable by
    ///         construction. Rejecting it at submission closes the DoS
    ///         surface where an attacker would have parked an unreachable
    ///         entry to brick the queue.
    function test_requestRedeem_floorAboveCurrentRate_reverts() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 currentRate = vault.exchangeRate();
        uint256 bobHdcl = vault.balanceOf(bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                HDCLVault.SlippageFloorAboveCurrentRate.selector,
                currentRate + 1,
                currentRate
            )
        );
        vault.requestRedeem(bobHdcl, currentRate + 1);
    }

    /// @notice Boundary: floor exactly at the current rate is accepted.
    function test_requestRedeem_floorEqualToCurrentRate_accepts() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 currentRate = vault.exchangeRate();
        uint256 bobHdcl = vault.balanceOf(bob);

        vm.prank(bob);
        uint256 reqId = vault.requestRedeem(bobHdcl, currentRate);

        (, , , bool active) = vault.getRedemptionRequest(reqId);
        assertTrue(active, "request created with floor exactly at current rate");
    }

    /// @notice Regression for the audit-finding attack: `type(uint256).max`
    ///         was the original DoS payload. The cap rejects it.
    function test_requestRedeem_maxUintFloor_reverts() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        vault.requestRedeem(bobHdcl, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PARK-AND-SKIP — floor breached after submission
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The audit-finding regression: a parked entry must NOT block
    ///         entries behind it. Bob submits at the highest legal floor, a
    ///         principal-mismatch shortfall drops the rate below the floor,
    ///         and Charlie (no floor) is still fulfilled — past Bob's park.
    function test_park_doesNotBlockSubsequentEntries() public {
        uint256 rateAtSubmission = _setupForRateDrop();

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobReqId = vault.requestRedeem(bobHdcl, rateAtSubmission);
        assertEq(bobReqId, 0, "bob at queueHead");

        uint256 charlieHdcl = vault.balanceOf(charlie);
        vm.prank(charlie);
        vault.requestRedeem(charlieHdcl, 0);

        _scheduleShortfall(100e18);

        uint256 bobBefore = hollar.balanceOf(bob);
        uint256 charlieBefore = hollar.balanceOf(charlie);

        // _processPositionFull's last step triggers internal pokeQueue with
        // the post-shortfall rate. Bob's floor is now above the rate (parked),
        // Charlie has no floor (fulfilled past Bob).
        _processPositionFull(0);

        assertEq(
            hollar.balanceOf(bob),
            bobBefore,
            "bob parked, no HOLLAR delivered"
        );
        assertGt(
            hollar.balanceOf(charlie),
            charlieBefore,
            "charlie fulfilled past bob's parked entry"
        );
        assertEq(
            vault.queueHead(),
            bobReqId,
            "queueHead pinned at bob's parked slot"
        );
        assertEq(
            vault.totalQueuedHdcl(),
            bobHdcl,
            "only bob's escrow remains queued"
        );
    }

    /// @notice After the rate climbs back above the parked floor (via yield
    ///         accrual on remaining active positions), the parked entry
    ///         fulfills on the next pokeQueue. No resubmit required.
    function test_park_recoversAndFulfillsAutomatically() public {
        uint256 rateAtSubmission = _setupForRateDrop();

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, rateAtSubmission);

        _scheduleShortfall(50e18);
        uint256 bobBefore = hollar.balanceOf(bob);
        _processPositionFull(0);

        // Sanity: bob is parked — his HOLLAR balance didn't move.
        assertEq(hollar.balanceOf(bob), bobBefore, "bob parked after shortfall");
        assertGt(vault.totalQueuedHdcl(), 0, "bob's escrow still pending");

        // Yield accrues on bob's & charlie's still-active positions until the
        // rate climbs back above bob's floor. A year is more than enough.
        _warpDays(365);
        vault.pokeQueue();

        assertGt(hollar.balanceOf(bob), bobBefore, "bob fulfilled after rate recovered");
    }

    /// @notice Across multiple pokeQueue calls while the rate stays below the
    ///         floor, the parked entry stays put — queueHead never advances,
    ///         totalQueuedHdcl unchanged. Replaces the pre-fix
    ///         "blockedQueueRemainsBlocked" assertion (the queue was blocked
    ///         globally then; now only the parked entry stays).
    function test_park_remainsParkedAcrossCalls() public {
        uint256 rateAtSubmission = _setupForRateDrop();

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, rateAtSubmission);

        // Large shortfall keeps the rate suppressed across multiple short pokes.
        _scheduleShortfall(1_000e18);
        _processPositionFull(0);

        uint256 queuedAfterFirst = vault.totalQueuedHdcl();
        uint256 headAfterFirst = vault.queueHead();
        assertEq(queuedAfterFirst, bobHdcl, "bob still parked after first process");

        // Subsequent pokes without enough time for recovery — entry stays parked.
        vault.pokeQueue();
        vault.pokeQueue();
        vault.pokeQueue();

        assertEq(vault.totalQueuedHdcl(), queuedAfterFirst, "queued HDCL unchanged");
        assertEq(vault.queueHead(), headAfterFirst, "queueHead unchanged");
    }

    /// @notice A parked user can still cancel their own request. The HDCL is
    ///         refunded and queueHead sweeps past the now-cancelled slot.
    function test_park_userCanCancelForRefund() public {
        uint256 rateAtSubmission = _setupForRateDrop();

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobReqId = vault.requestRedeem(bobHdcl, rateAtSubmission);

        _scheduleShortfall(100e18);
        _processPositionFull(0);

        // Bob is parked; HDCL still escrowed in vault.
        assertEq(vault.balanceOf(bob), 0, "bob's HDCL escrowed in vault");

        vm.prank(bob);
        vault.cancelRedeem(bobReqId);

        assertEq(vault.balanceOf(bob), bobHdcl, "bob got HDCL back");
        // queueHead advances through bob's now-empty slot. charlie's
        // request (if any) wasn't created in this test, so head lands at 1.
        assertEq(vault.queueHead(), bobReqId + 1, "queueHead past cancelled park");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   AUDIT FINDING #1 REGRESSION — combined scenario
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice End-to-end regression for the Pashov finding: even with three
    ///         users in front of charlie, all using the highest legal floor,
    ///         a shortfall that parks ALL of them must NOT prevent charlie's
    ///         no-floor request from being served.
    function test_auditFinding1_multipleParkedEntries_doNotBlockNoFloorEntry() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);
        _deposit(charlie, 1_000e18);
        _warpDays(61);

        uint256 rate = vault.exchangeRate();

        // Three slippage-protected entries from bob (split into 3 requests
        // to verify multiple parks scan past correctly).
        uint256 chunk = vault.balanceOf(bob) / 3;
        vm.startPrank(bob);
        vault.requestRedeem(chunk, rate);
        vault.requestRedeem(chunk, rate);
        vault.requestRedeem(chunk, rate);
        vm.stopPrank();

        // Charlie behind them with no floor.
        uint256 charlieHdcl = vault.balanceOf(charlie);
        vm.prank(charlie);
        vault.requestRedeem(charlieHdcl, 0);

        _scheduleShortfall(100e18);
        uint256 charlieBefore = hollar.balanceOf(charlie);
        _processPositionFull(0);

        assertGt(
            hollar.balanceOf(charlie),
            charlieBefore,
            "charlie served past three parked entries"
        );
        assertEq(
            vault.queueHead(),
            0,
            "queueHead pinned at first parked entry"
        );
    }
}
