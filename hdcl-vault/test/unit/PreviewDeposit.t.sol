// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";

/// @title previewDeposit Edge Case Coverage
/// @notice Verifies previewDeposit returns 0 instead of underflowing on first
///         deposits below DEAD_SHARES, and matches the actual mint amount in
///         normal operation.
contract PreviewDepositTest is BaseTest {
    uint256 constant DEAD_SHARES = 1000;

    // ═══════════════════════════════════════════════════════════════════════
    //   FIRST DEPOSIT (supply == 0): edge cases
    // ═══════════════════════════════════════════════════════════════════════

    function test_previewDeposit_firstDepositZeroAmount_returnsZero() public view {
        assertEq(vault.previewDeposit(0), 0, "0 amount returns 0");
    }

    function test_previewDeposit_firstDepositBelowDeadShares_returnsZero() public view {
        // amount < DEAD_SHARES would underflow under old code; must return 0 now
        assertEq(vault.previewDeposit(1), 0, "1 wei returns 0");
        assertEq(vault.previewDeposit(500), 0, "500 wei returns 0");
        assertEq(vault.previewDeposit(DEAD_SHARES - 1), 0, "999 wei returns 0");
    }

    function test_previewDeposit_firstDepositAtDeadShares_returnsZero() public view {
        // hollarAmount == DEAD_SHARES would also revert in deposit (require > DEAD_SHARES)
        assertEq(vault.previewDeposit(DEAD_SHARES), 0, "exactly DEAD_SHARES returns 0");
    }

    function test_previewDeposit_firstDepositJustAboveDeadShares_returnsOne() public view {
        // hollarAmount = DEAD_SHARES + 1 → deposit succeeds with 1 HDCL minted
        assertEq(vault.previewDeposit(DEAD_SHARES + 1), 1, "DEAD_SHARES + 1 -> 1 HDCL");
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

    function test_previewDeposit_zeroAmountAfterFirstDeposit_returnsZero() public {
        _deposit(alice, 10_000e18);
        assertEq(vault.previewDeposit(0), 0, "0 amount returns 0 even with supply>0");
    }
}
