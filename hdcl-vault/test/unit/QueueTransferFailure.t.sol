// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title HOLLAR Transfer Failure Resilience
/// @notice Verifies that a single failing HOLLAR transfer (e.g., a future
///         HOLLAR blacklist of a recipient) does not brick the redemption
///         queue. The failed user's HDCL is refunded, the queue advances,
///         and subsequent users get fulfilled.
contract QueueTransferFailureTest is BaseTest {
    bytes32 internal constant FAIL_TOPIC = keccak256(
        "RedemptionTransferFailed(uint256,address,uint256,uint256)"
    );

    function _seedIdle(address user, uint256 amount) internal {
        _deposit(user, amount);
        _warpDays(61);
        _processPositionFull(0);
    }

    function _findFailEvent() internal returns (
        bool found,
        uint256 reqId,
        address user,
        uint256 hollarAttempted,
        uint256 hdclRefunded
    ) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != FAIL_TOPIC) continue;
            reqId = uint256(logs[i].topics[1]);
            user = address(uint160(uint256(logs[i].topics[2])));
            (hollarAttempted, hdclRefunded) = abi.decode(
                logs[i].data,
                (uint256, uint256)
            );
            return (true, reqId, user, hollarAttempted, hdclRefunded);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FULL-FULFILL FAILURE: head user blocked, queue still advances
    // ═══════════════════════════════════════════════════════════════════════

    function test_blockedHead_doesNotBrickQueue() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);
        _deposit(charlie, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        uint256 charlieHdcl = vault.balanceOf(charlie);

        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);
        vm.prank(charlie);
        vault.requestRedeem(charlieHdcl, 0);

        // Bob is now blocked from receiving HOLLAR
        hollar.setBlocked(bob, true);

        uint256 bobHdclBefore = vault.balanceOf(bob);
        uint256 charlieHollarBefore = hollar.balanceOf(charlie);

        // Should NOT revert — queue keeps moving past bob
        vault.pokeQueue();

        // Bob got his HDCL back (refunded, no HOLLAR transferred)
        assertEq(
            vault.balanceOf(bob),
            bobHdclBefore + bobHdcl,
            "bob refunded full HDCL escrow"
        );

        // Charlie got HOLLAR (queue advanced past bob)
        assertGt(
            hollar.balanceOf(charlie),
            charlieHollarBefore,
            "charlie fulfilled despite bob being blocked"
        );

        // Queue is empty
        assertEq(vault.totalQueuedHdcl(), 0, "queue drained");
    }

    function test_blockedHead_emitsTransferFailedEvent() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);

        hollar.setBlocked(bob, true);

        vm.recordLogs();
        vault.pokeQueue();

        (
            bool found,
            ,
            address user,
            ,
            uint256 hdclRefunded
        ) = _findFailEvent();
        assertTrue(found, "RedemptionTransferFailed must fire");
        assertEq(user, bob, "event user is bob");
        assertEq(hdclRefunded, bobHdcl, "refunded == escrowed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PARTIAL-FULFILL FAILURE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When the head request would only be partially fulfilled but the
    ///         transfer fails, we refund the user's full outstanding HDCL and
    ///         continue with the next entry.
    function test_blockedHead_partialFulfillment_refundsFullEscrow() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 5 * TEN_THOUSAND_HOLLAR); // big deposit so partial fill is forced
        _deposit(charlie, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        uint256 charlieHdcl = vault.balanceOf(charlie);

        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0); // can't be fully filled with current idle
        vm.prank(charlie);
        vault.requestRedeem(charlieHdcl, 0);

        hollar.setBlocked(bob, true);

        uint256 bobHdclBefore = vault.balanceOf(bob);

        vault.pokeQueue();

        // Bob refunded ALL his outstanding HDCL (not just the partial portion)
        assertEq(
            vault.balanceOf(bob),
            bobHdclBefore + bobHdcl,
            "bob got full refund"
        );

        // Bob's request removed
        (address u,,,) = vault.getRedemptionRequest(0);
        assertEq(u, address(0), "bob's request deleted");
    }

    // Note: two earlier tests (`test_userCanReRequestAfterUnblock`,
    // `test_failedTransfer_preservesIdleHollar`) were removed when the
    // `pokeQueue` reinvest gate was switched from a static `queueCanProgress`
    // flag to the actual `hollarUsed` returned by the processor (audit
    // finding #5). Those tests asserted that `pokeQueue` leaves idleHollar
    // untouched after a failed-transfer refund — which is no longer the
    // case, because a refund-only call now correctly recognises that no
    // HOLLAR moved and triggers reinvest of the idle balance.
    //
    // Current HOLLAR (Aave GHO fork at /hollar) has no blacklist, denylist,
    // freeze, pause, or sanctions mechanism — `transfer` cannot fail per
    // recipient. The remaining tests in this file still exercise the
    // defensive `_tryHollarTransfer` path against the mock's `setBlocked`,
    // covering hypothetical future HOLLAR upgrades.

    // ═══════════════════════════════════════════════════════════════════════
    //   pokeDecentral on principal-redeem with blocked queue head
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The internal _processQueueWithHollar inside pokeDecentral
    ///         (after principal redemption) must also handle blocked head.
    function test_pokeDecentral_blockedHead_doesNotRevert() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);

        // Bob queues redemption first (will be at head when alice's position completes)
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);

        hollar.setBlocked(bob, true);

        // Process alice's position fully — this triggers internal pokeQueue
        // after principal redemption. Must not revert.
        _warpDays(61);
        _processPositionFull(0); // would revert if blocked head bricks the internal queue

        // Bob refunded
        assertGt(vault.balanceOf(bob), 0, "bob has HDCL refund");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Multiple blocked entries
    // ═══════════════════════════════════════════════════════════════════════

    function test_multipleBlockedEntries_allRefunded() public {
        _seedIdle(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 1_000e18);
        _deposit(charlie, 1_000e18);

        uint256 bobHdcl = vault.balanceOf(bob);
        uint256 charlieHdcl = vault.balanceOf(charlie);

        vm.prank(bob);
        vault.requestRedeem(bobHdcl, 0);
        vm.prank(charlie);
        vault.requestRedeem(charlieHdcl, 0);

        // Both blocked
        hollar.setBlocked(bob, true);
        hollar.setBlocked(charlie, true);

        vault.pokeQueue();

        assertEq(vault.balanceOf(bob), bobHdcl, "bob got HDCL back");
        assertEq(vault.balanceOf(charlie), charlieHdcl, "charlie got HDCL back");
        assertEq(vault.totalQueuedHdcl(), 0, "queue drained");
    }
}
