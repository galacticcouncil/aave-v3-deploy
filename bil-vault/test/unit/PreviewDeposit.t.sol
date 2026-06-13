// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @title previewDeposit Edge Case Coverage
/// @notice Verifies previewDeposit reverts on the same math edges that the
///         actual `deposit` call reverts on (ERC-4626 §previewDeposit
///         conformance), and that the happy-path return value matches the
///         shares minted by a same-tx `deposit` call.
contract PreviewDepositTest is BaseTest {
    uint256 constant DEAD_SHARES = 1000;

    // ═══════════════════════════════════════════════════════════════════════
    //   FIRST DEPOSIT (supply == 0): math-edge reverts mirror deposit's
    // ═══════════════════════════════════════════════════════════════════════

    function test_previewDeposit_firstDepositZeroAmount_reverts() public {
        vm.expectRevert(BILVault.ZeroAmount.selector);
        vault.previewDeposit(0);
    }

    function test_previewDeposit_firstDepositBelowDeadShares_reverts() public {
        // amount <= DEAD_SHARES reverts in deposit → must revert in preview too.
        vm.expectRevert(BILVault.DepositTooSmall.selector);
        vault.previewDeposit(1);
        vm.expectRevert(BILVault.DepositTooSmall.selector);
        vault.previewDeposit(500);
        vm.expectRevert(BILVault.DepositTooSmall.selector);
        vault.previewDeposit(DEAD_SHARES - 1);
    }

    function test_previewDeposit_firstDepositAtDeadShares_reverts() public {
        vm.expectRevert(BILVault.DepositTooSmall.selector);
        vault.previewDeposit(DEAD_SHARES);
    }

    function test_previewDeposit_firstDepositJustAboveDeadShares_returnsOne() public view {
        // hollarAmount = DEAD_SHARES + 1 → deposit succeeds with 1 BIL minted
        assertEq(vault.previewDeposit(DEAD_SHARES + 1), 1, "DEAD_SHARES + 1 -> 1 BIL");
    }

    function test_previewDeposit_firstDepositNormalAmount_matchesActual() public {
        uint256 amount = 10_000e18;
        uint256 previewed = vault.previewDeposit(amount);
        assertEq(previewed, amount - DEAD_SHARES, "preview matches first-deposit math");

        // Confirm with the real deposit
        vm.prank(alice);
        uint256 actual = vault.deposit(amount, alice);
        assertEq(actual, previewed, "actual mint matches preview");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   LATER DEPOSITS (supply > 0): preview matches actual
    // ═══════════════════════════════════════════════════════════════════════

    function test_previewDeposit_secondDeposit_matchesActual() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);

        uint256 amount = 5_000e18;
        uint256 previewed = vault.previewDeposit(amount);

        vm.prank(bob);
        uint256 actual = vault.deposit(amount, bob);
        assertEq(actual, previewed, "preview matches actual mint after seeded vault");
    }

    function test_previewDeposit_zeroAmountAfterFirstDeposit_reverts() public {
        _deposit(alice, 10_000e18);
        vm.expectRevert(BILVault.ZeroAmount.selector);
        vault.previewDeposit(0);
    }
}
