// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {IERC4626} from "../../src/interfaces/IERC4626.sol";
import {IERC7540Operator, IERC7540Redeem} from "../../src/interfaces/IERC7540.sol";

/// @title ERC-7540 Views + ERC-165 (W2d)
contract ERC7540ViewsTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════
    //   pendingRedeemRequest / claimableRedeemRequest across the lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    function test_pending_freshRequest_isFull() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 reqId = _requestRedeem(alice, aliceBil / 4);

        // Right after requestRedeem, everything is pending; nothing claimable.
        assertEq(vault.pendingRedeemRequest(reqId, alice), aliceBil / 4, "all pending");
        assertEq(vault.claimableRedeemRequest(reqId, alice), 0, "nothing claimable");
    }

    function test_pending_wrongController_returnsZero() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 reqId = _requestRedeem(alice, aliceBil / 4);

        // Bob asking about alice's request gets 0 (he's not the controller).
        assertEq(vault.pendingRedeemRequest(reqId, bob), 0, "bob sees nothing pending");
        assertEq(vault.claimableRedeemRequest(reqId, bob), 0, "bob sees nothing claimable");
    }

    function test_claimable_afterFullSettle() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        uint256 reqId = _requestRedeem(alice, aliceBil / 4);

        vault.pokeQueue();

        // Fully rate-locked: pending == 0, claimable == redeemAmount
        assertEq(vault.pendingRedeemRequest(reqId, alice), 0, "fully settled - nothing pending");
        assertEq(vault.claimableRedeemRequest(reqId, alice), aliceBil / 4, "all claimable");
    }

    function test_partialSettle_splitsPendingAndClaimable() public {
        // Limited idle → partial settle
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0); // idle ≈ 10,300

        _deposit(bob, 50_000e18); // creates position 1; idle unchanged
        uint256 bobBil = vault.balanceOf(bob);
        uint256 reqId = _requestRedeem(bob, bobBil);

        vault.pokeQueue();

        uint256 pending = vault.pendingRedeemRequest(reqId, bob);
        uint256 claimable = vault.claimableRedeemRequest(reqId, bob);

        assertGt(claimable, 0, "partial settle made some claimable");
        assertGt(pending, 0, "rest stays pending");
        assertEq(pending + claimable, bobBil, "pending + claimable == original");
    }

    function test_claimable_dropsAfterRedeem() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        uint256 reqId = _requestRedeem(alice, aliceBil / 4);
        vault.pokeQueue();

        uint256 claimableBefore = vault.claimableRedeemRequest(reqId, alice);
        assertGt(claimableBefore, 0);

        // Partial claim
        vm.prank(alice);
        vault.redeem(claimableBefore / 2, alice, alice);

        // Half consumed
        assertApproxEqAbs(vault.claimableRedeemRequest(reqId, alice), claimableBefore / 2, 1);
    }

    function test_pending_dropsAfterCancel() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 reqId = _requestRedeem(alice, aliceBil / 4);

        assertEq(vault.pendingRedeemRequest(reqId, alice), aliceBil / 4);

        vm.prank(alice);
        vault.cancelRedeem(reqId);

        // Fully cancelled (nothing was settled) → request gone
        assertEq(vault.pendingRedeemRequest(reqId, alice), 0, "cancelled -pending zero");
        assertEq(vault.claimableRedeemRequest(reqId, alice), 0, "cancelled -claimable zero");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      ERC-165 interface detection
    // ═══════════════════════════════════════════════════════════════════════

    function test_supportsInterface_ERC4626() public view {
        assertTrue(vault.supportsInterface(type(IERC4626).interfaceId), "ERC-4626 declared");
    }

    function test_supportsInterface_ERC7540Operator() public view {
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId), "ERC-7540 Operator declared");
    }

    function test_supportsInterface_ERC7540Redeem() public view {
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId), "ERC-7540 Redeem declared");
    }

    function test_supportsInterface_ERC165() public view {
        // 0x01ffc9a7 is the canonical ERC-165 interface ID
        assertTrue(vault.supportsInterface(0x01ffc9a7), "ERC-165 declared (inherited)");
    }

    function test_supportsInterface_unknownReturnsFalse() public view {
        assertFalse(vault.supportsInterface(0xdeadbeef), "random ID rejected");
        assertFalse(vault.supportsInterface(0xffffffff), "0xffffffff rejected per ERC-165 spec");
    }
}
