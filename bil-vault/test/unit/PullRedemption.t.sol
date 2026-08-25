// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {QueueLib} from "../../src/libraries/QueueLib.sol";

/// @title Pull-Redemption Mechanics (W2b)
/// @notice Verifies the rate-lock-then-claim model: pokeQueue locks rates and
///         reserves HOLLAR; users call redeem/withdraw to actually receive it.
contract PullRedemptionTest is BaseTest {
    /// @dev Canonical ERC-4626/7540 withdraw event
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    // ═══════════════════════════════════════════════════════════════════════
    //   Rate-lock on pokeQueue, no transfer
    // ═══════════════════════════════════════════════════════════════════════

    function test_pokeQueue_rateLocksWithoutTransfer() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 redeemAmt = aliceBil / 4;
        uint256 requestId = _requestRedeem(alice, redeemAmt);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);
        uint256 vaultBalBefore = hollar.balanceOf(address(vault));
        uint256 idleBefore = vault.idleHollar();

        vault.pokeQueue();

        // No HOLLAR moved out of the vault
        assertEq(hollar.balanceOf(alice), aliceHollarBefore, "alice still has no HOLLAR after pokeQueue");
        assertEq(hollar.balanceOf(address(vault)), vaultBalBefore, "vault HOLLAR balance unchanged");

        // HOLLAR moved from idle to reserved
        assertLt(vault.idleHollar(), idleBefore, "idle decreased");
        assertGt(vault.totalReservedHollar(), 0, "reserved increased");

        // Request is rate-locked: bilSettled == bilAmount
        (, uint256 amt, uint256 settled, uint256 owed,) = vault.getRedemptionRequest(requestId);
        assertEq(settled, amt, "fully settled");
        assertGt(owed, 0, "HOLLAR locked for claim");
    }

    function test_totalAssets_includesReserved() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 totalAssetsBefore = vault.totalAssets();

        _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        // totalAssets shouldn't drop just because HOLLAR moved from idle to reserved
        assertApproxEqRel(
            vault.totalAssets(),
            totalAssetsBefore,
            0.0001e18,
            "totalAssets preserved across rate-lock"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   redeem(shares, receiver, controller)
    // ═══════════════════════════════════════════════════════════════════════

    function test_redeem_burnsAndPays() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        uint256 supplyBefore = vault.totalSupply();
        uint256 aliceHollarBefore = hollar.balanceOf(alice);
        uint256 reservedBefore = vault.totalReservedHollar();

        vm.prank(alice);
        uint256 assets = vault.redeem(aliceBil / 4, alice, alice);

        // hDCL burned
        assertEq(vault.totalSupply(), supplyBefore - aliceBil / 4, "hDCL burned at claim");
        // HOLLAR transferred
        assertEq(hollar.balanceOf(alice) - aliceHollarBefore, assets, "alice received assets");
        // Reserved decremented
        assertEq(vault.totalReservedHollar(), reservedBefore - assets, "reserved decreased");
    }

    function test_redeem_canPayToReceiver() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        uint256 bobHollarBefore = hollar.balanceOf(bob);

        vm.prank(alice);
        vault.redeem(aliceBil / 4, bob, alice);

        assertGt(hollar.balanceOf(bob), bobHollarBefore, "bob (receiver) got HOLLAR");
        // Alice's hDCL was burned (escrowed); her HOLLAR balance shouldn't change here
        assertEq(hollar.balanceOf(alice), 100_000e18 - TEN_THOUSAND_HOLLAR, "alice's HOLLAR unchanged");
    }

    function test_redeem_revertsWhenControllerIsNotSender() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        // Bob tries to claim alice's redemption
        vm.prank(bob);
        vm.expectRevert(BILVault.NotAuthorized.selector);
        vault.redeem(aliceBil / 4, bob, alice);
    }

    function test_redeem_revertsOnInsufficientClaimable() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        // Try to claim more than settled
        vm.prank(alice);
        vm.expectRevert(QueueLib.InsufficientClaimable.selector);
        vault.redeem(aliceBil, alice, alice);
    }

    function test_redeem_emitsWithdrawEvent() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        uint256 redeemAmt = aliceBil / 4;
        _requestRedeem(alice, redeemAmt);
        vault.pokeQueue();

        // We don't know the exact assets ahead of time, just that the event fires
        vm.recordLogs();

        vm.prank(alice);
        vault.redeem(redeemAmt, alice, alice);

        // Confirm via decoded log shape
        bytes32 sig = keccak256("Withdraw(address,address,address,uint256,uint256)");
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Withdraw event emitted");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   withdraw(assets, receiver, controller)
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_burnsExactAssets() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        // Get the request's owed HOLLAR
        (,,, uint256 owed,) = vault.getRedemptionRequest(0);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(owed, alice, alice);

        assertEq(hollar.balanceOf(alice) - aliceHollarBefore, owed, "alice received exact assets");
        assertEq(sharesBurned, aliceBil / 4, "all settled shares consumed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Cancel with settled portion
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancel_keepsSettledAlive() public {
        // Setup: limited idle so settle is partial. Alice's position gives
        // ~10_300 HOLLAR idle. Bob deposits much more to get hDCL well in
        // excess of idle, then redeems all of it.
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0); // idle ≈ 10,300

        _deposit(bob, 50_000e18); // creates position 1; idle unchanged
        uint256 bobBil = vault.balanceOf(bob);
        uint256 reqId = _requestRedeem(bob, bobBil);

        // pokeQueue partially settles bob
        vault.pokeQueue();

        (, uint256 amt, uint256 settledBefore, uint256 owedBefore,) = vault.getRedemptionRequest(reqId);
        assertGt(settledBefore, 0, "partially settled");
        assertLt(settledBefore, amt, "not fully settled");

        // Bob cancels — only unsettled portion refunded; settled stays alive
        uint256 bobBilBefore = vault.balanceOf(bob);
        vm.prank(bob);
        vault.cancelRedeem(reqId);
        uint256 bobBilAfter = vault.balanceOf(bob);

        // Bob got the unsettled portion back as hDCL
        assertEq(bobBilAfter - bobBilBefore, amt - settledBefore, "unsettled refunded");

        // Request still alive with the settled portion
        (, uint256 amtAfter, uint256 settledAfter, uint256 owedAfter, bool active) = vault.getRedemptionRequest(reqId);
        assertTrue(active, "request still alive");
        assertEq(amtAfter, settledBefore, "amount shrunk to settled");
        assertEq(settledAfter, settledBefore, "settled unchanged");
        assertEq(owedAfter, owedBefore, "owed unchanged");

        // Bob can still claim the settled portion
        uint256 bobHollarBefore = hollar.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(settledBefore, bob, bob);
        assertGt(hollar.balanceOf(bob), bobHollarBefore, "settled portion claimable after cancel");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Multi-request claim
    // ═══════════════════════════════════════════════════════════════════════

    function test_claim_acrossMultipleRequests() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // Alice makes two separate requests
        _requestRedeem(alice, 1_000e18);
        _requestRedeem(alice, 2_000e18);

        vault.pokeQueue();

        // Claim across both requests in one redeem
        uint256 aliceHollarBefore = hollar.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(3_000e18, alice, alice);

        assertGt(hollar.balanceOf(alice) - aliceHollarBefore, 0, "received HOLLAR");
        assertEq(hollar.balanceOf(alice) - aliceHollarBefore, assets, "balance change = assets");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Helpers
    // ═══════════════════════════════════════════════════════════════════════

    // Re-export the Vm type since this test uses recordLogs
    // (Foundry pulls Vm via forge-std/Test, imported via BaseTest)
}

import {Vm} from "forge-std/Vm.sol";
