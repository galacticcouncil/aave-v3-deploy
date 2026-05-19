// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title ERC-7540 Operator + CLAIM_OPERATOR_ROLE (W2c)
/// @notice Verifies the three claim auth paths:
///         1. msg.sender == controller (self-claim, covered in PullRedemption.t.sol)
///         2. isOperator[controller][msg.sender] (user-approved per-controller operator)
///         3. CLAIM_OPERATOR_ROLE + autoClaimEnabled[controller] + receiver == controller
contract OperatorAndAutoClaimTest is BaseTest {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event AutoClaimSet(address indexed controller, bool enabled);

    // ═══════════════════════════════════════════════════════════════════════
    //   setOperator + isOperator
    // ═══════════════════════════════════════════════════════════════════════

    function test_setOperator_setsAndUnsets() public {
        assertFalse(vault.isOperator(alice, bob));

        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob));

        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob));
    }

    function test_setOperator_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit OperatorSet(alice, bob, true);
        vm.prank(alice);
        vault.setOperator(bob, true);
    }

    function test_setOperator_revertsOnZeroOperator() public {
        vm.expectRevert(HDCLVault.ZeroAddress.selector);
        vm.prank(alice);
        vault.setOperator(address(0), true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Operator-initiated requestRedeem
    // ═══════════════════════════════════════════════════════════════════════

    function test_requestRedeem_byOperator_succeeds() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(alice);
        vault.setOperator(bob, true);

        // Bob initiates a redemption on alice's behalf
        vm.prank(bob);
        uint256 reqId = vault.requestRedeem(aliceHdcl / 4, alice, alice);

        // Alice's hDCL was escrowed, request is alice's
        (address controller, , , ,) = vault.getRedemptionRequest(reqId);
        assertEq(controller, alice);
    }

    function test_requestRedeem_byNonOperator_reverts() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Bob is NOT an operator. Cannot initiate on alice's behalf.
        vm.prank(bob);
        vm.expectRevert(HDCLVault.NotAuthorized.selector);
        vault.requestRedeem(aliceHdcl / 4, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Operator-initiated claim (redeem/withdraw)
    // ═══════════════════════════════════════════════════════════════════════

    function _settleAlice() internal returns (uint256 settledShares) {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        settledShares = aliceHdcl / 4;
        _requestRedeem(alice, settledShares);
        vault.pokeQueue();
    }

    function test_redeem_byOperator_canRedirectToOtherReceiver() public {
        uint256 settled = _settleAlice();

        vm.prank(alice);
        vault.setOperator(bob, true);

        uint256 charlieHollarBefore = hollar.balanceOf(charlie);

        // Bob claims on alice's behalf, paying to charlie (a different receiver)
        vm.prank(bob);
        vault.redeem(settled, charlie, alice);

        assertGt(hollar.balanceOf(charlie), charlieHollarBefore, "charlie got HOLLAR");
    }

    function test_redeem_byNonOperator_reverts() public {
        uint256 settled = _settleAlice();

        // Bob is not an operator and not the controller. Reverts.
        vm.prank(bob);
        vm.expectRevert(HDCLVault.NotAuthorized.selector);
        vault.redeem(settled, alice, alice);
    }

    function test_withdraw_byOperator_works() public {
        _settleAlice();
        (,,, uint256 owed,) = vault.getRedemptionRequest(0);

        vm.prank(alice);
        vault.setOperator(bob, true);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        vm.prank(bob);
        vault.withdraw(owed, alice, alice);

        assertEq(hollar.balanceOf(alice) - aliceHollarBefore, owed, "alice received HOLLAR via operator withdraw");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   setAutoClaim
    // ═══════════════════════════════════════════════════════════════════════

    function test_setAutoClaim_togglesAndEmits() public {
        assertFalse(vault.autoClaimEnabled(alice));

        vm.expectEmit(true, false, false, true);
        emit AutoClaimSet(alice, true);
        vm.prank(alice);
        vault.setAutoClaim(true);

        assertTrue(vault.autoClaimEnabled(alice));

        vm.prank(alice);
        vault.setAutoClaim(false);
        assertFalse(vault.autoClaimEnabled(alice));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   CLAIM_OPERATOR_ROLE auto-claim
    // ═══════════════════════════════════════════════════════════════════════

    address internal keeperBot = makeAddr("keeperBot");

    function _grantClaimOperator() internal {
        bytes32 role = vault.CLAIM_OPERATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(role, keeperBot);
    }

    function test_autoClaim_succeedsWhenOptedIn() public {
        uint256 settled = _settleAlice();

        // Alice opts in to auto-claim
        vm.prank(alice);
        vault.setAutoClaim(true);

        _grantClaimOperator();

        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        // Keeper auto-claims for alice. Receiver must be alice (controller).
        vm.prank(keeperBot);
        vault.redeem(settled, alice, alice);

        assertGt(hollar.balanceOf(alice), aliceHollarBefore, "alice received HOLLAR via auto-claim");
    }

    function test_autoClaim_revertsWhenNotOptedIn() public {
        uint256 settled = _settleAlice();

        _grantClaimOperator();

        // Alice did NOT opt in.
        vm.prank(keeperBot);
        vm.expectRevert(HDCLVault.NotAuthorized.selector);
        vault.redeem(settled, alice, alice);
    }

    function test_autoClaim_cannotRedirectReceiver() public {
        uint256 settled = _settleAlice();

        vm.prank(alice);
        vault.setAutoClaim(true);

        _grantClaimOperator();

        // Keeper has role + alice opted in, BUT tries to redirect HOLLAR to bob.
        // Must revert: receiver == controller is load-bearing.
        vm.prank(keeperBot);
        vm.expectRevert(HDCLVault.NotAuthorized.selector);
        vault.redeem(settled, bob, alice);
    }

    function test_autoClaim_optingOutBlocksFutureClaim() public {
        _settleAlice();

        vm.prank(alice);
        vault.setAutoClaim(true);

        _grantClaimOperator();

        // Claim once (succeeds)
        (,, uint256 settled1,,) = vault.getRedemptionRequest(0);
        vm.prank(keeperBot);
        vault.redeem(settled1, alice, alice);

        // Set up a second request + settle
        uint256 aliceHdcl = vault.balanceOf(alice);
        _requestRedeem(alice, aliceHdcl / 4);
        vault.pokeQueue();

        // Alice opts out
        vm.prank(alice);
        vault.setAutoClaim(false);

        // Keeper can no longer claim
        uint256 reqId = vault.getRedemptionQueueLength() - 1;
        (,, uint256 settled2,,) = vault.getRedemptionRequest(reqId);
        if (settled2 > 0) {
            vm.prank(keeperBot);
            vm.expectRevert(HDCLVault.NotAuthorized.selector);
            vault.redeem(settled2, alice, alice);
        }
    }

    function test_autoClaim_rolelessAddressRejected() public {
        uint256 settled = _settleAlice();

        vm.prank(alice);
        vault.setAutoClaim(true);

        // keeperBot does NOT hold CLAIM_OPERATOR_ROLE
        vm.prank(keeperBot);
        vm.expectRevert(HDCLVault.NotAuthorized.selector);
        vault.redeem(settled, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Cancel via operator
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancel_byOperator_refundsToController() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 reqId = _requestRedeem(alice, aliceHdcl / 4);

        vm.prank(alice);
        vault.setOperator(bob, true);

        uint256 aliceHdclBefore = vault.balanceOf(alice);
        uint256 bobHdclBefore = vault.balanceOf(bob);

        // Bob cancels alice's request
        vm.prank(bob);
        vault.cancelRedeem(reqId);

        // Refund goes to alice (controller), not bob (operator)
        assertGt(vault.balanceOf(alice), aliceHdclBefore, "alice got hDCL refund");
        assertEq(vault.balanceOf(bob), bobHdclBefore, "bob (operator) got nothing");
    }
}
