// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @title ERC-4626 Base Surface (W2a)
/// @notice Covers the synchronous-deposit half of ERC-4626 conformance.
///         Async redemption (ERC-7540) lives in its own test file.
contract ERC4626Test is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════
    //                          asset()
    // ═══════════════════════════════════════════════════════════════════════

    function test_asset_returnsHollar() public view {
        assertEq(vault.asset(), address(hollar));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  convertToShares / convertToAssets
    // ═══════════════════════════════════════════════════════════════════════

    function test_convertToShares_emptySupply_isOneToOne() public view {
        assertEq(vault.convertToShares(1_000e18), 1_000e18);
    }

    function test_convertToAssets_emptySupply_isOneToOne() public view {
        assertEq(vault.convertToAssets(1_000e18), 1_000e18);
    }

    function test_convertToShares_afterDeposit_reflectsRate() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);

        uint256 expected = (1_000e18 * vault.totalSupply()) / vault.totalAssets();
        assertEq(vault.convertToShares(1_000e18), expected);
    }

    function test_convertToAssets_afterDeposit_reflectsRate() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);

        uint256 expected = (1_000e18 * vault.totalAssets()) / vault.totalSupply();
        assertEq(vault.convertToAssets(1_000e18), expected);
    }

    function test_convertToShares_zeroSupplyButAssets_returnsZero() public view {
        // No deposits yet: empty supply → 1:1, not the catastrophic path
        assertEq(vault.convertToShares(0), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       maxDeposit / maxMint
    // ═══════════════════════════════════════════════════════════════════════

    function test_maxDeposit_returnsTvlCapHeadroom() public {
        assertEq(vault.maxDeposit(alice), INITIAL_TVL_CAP);

        _deposit(alice, 10_000e18);
        // After deposit, totalAssets is at least 10_000e18 (some yield may have accrued)
        assertLe(vault.maxDeposit(alice), INITIAL_TVL_CAP - 10_000e18);
    }

    function test_maxDeposit_zeroWhenDepositsPaused() public {
        vm.prank(admin);
        vault.pauseDeposits();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_zeroWhenPaused() public {
        vm.prank(admin);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_zeroAtCap() public {
        vm.prank(admin);
        vault.setTvlCap(10_000e18);

        _deposit(alice, 10_000e18);
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxMint_reflectsCurrentRate() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);

        uint256 cap = vault.maxDeposit(alice);
        uint256 expected = vault.convertToShares(cap);
        assertEq(vault.maxMint(alice), expected);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       maxWithdraw / maxRedeem
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sync withdraw/redeem is unsupported (async-only).
    function test_maxWithdraw_alwaysZero() public view {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_alwaysZero() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          previewMint
    // ═══════════════════════════════════════════════════════════════════════

    function test_previewMint_firstDeposit_includesDeadShares() public view {
        // To mint S shares to caller on first deposit, must pay S + DEAD_SHARES.
        // DEAD_SHARES = 1000.
        assertEq(vault.previewMint(10_000e18), 10_000e18 + 1000);
    }

    function test_previewMint_afterDeposit_roundsUp() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);

        uint256 supply = vault.totalSupply();
        uint256 totalA = vault.totalAssets();
        uint256 shares = 1_234e18;
        uint256 expected = (shares * totalA + supply - 1) / supply;
        assertEq(vault.previewMint(shares), expected);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       deposit(assets, receiver)
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_canSpecifyReceiver() public {
        // Alice pays HOLLAR; Bob receives the hDCL
        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e18, bob);

        assertEq(vault.balanceOf(alice), 0, "alice has no hDCL");
        assertEq(vault.balanceOf(bob), shares, "bob has hDCL");
    }

    function test_deposit_zeroReceiver_reverts() public {
        vm.prank(alice);
        vm.expectRevert(BILVault.ZeroAddress.selector);
        vault.deposit(10_000e18, address(0));
    }

    function test_deposit_emitsCanonicalDepositEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Deposit(alice, alice, 10_000e18, 10_000e18 - 1000);

        vm.prank(alice);
        vault.deposit(10_000e18, alice);
    }

    /// @dev mirror of canonical ERC-4626 event for the test's expectEmit
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    // ═══════════════════════════════════════════════════════════════════════
    //                       mint(shares, receiver)
    // ═══════════════════════════════════════════════════════════════════════

    function test_mint_pullsCorrectAssets() public {
        // Alice wants exactly 5000 shares as the first depositor.
        // She must overpay DEAD_SHARES (1000) to cover the dead-shares dust.
        uint256 want = 5_000e18;
        uint256 expectedAssets = vault.previewMint(want);

        vm.prank(alice);
        uint256 paid = vault.mint(want, alice);

        assertEq(paid, expectedAssets);
        assertEq(vault.balanceOf(alice), want);
    }

    function test_mint_canSpecifyReceiver() public {
        vm.prank(alice);
        vault.mint(5_000e18, bob);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 5_000e18);
    }

    function test_mint_zeroReceiver_reverts() public {
        vm.prank(alice);
        vm.expectRevert(BILVault.ZeroAddress.selector);
        vault.mint(5_000e18, address(0));
    }

    function test_mint_zeroShares_reverts() public {
        vm.prank(alice);
        vm.expectRevert(BILVault.ZeroAmount.selector);
        vault.mint(0, alice);
    }

    function test_mint_revertsWhenPaused() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.prank(alice);
        vm.expectRevert(BILVault.DepositsArePaused.selector);
        vault.mint(5_000e18, alice);
    }

    function test_mint_revertsWhenCapWouldBeExceeded() public {
        vm.prank(admin);
        vault.setTvlCap(10_000e18);

        vm.prank(alice);
        vm.expectRevert(BILVault.ExceedsTvlCap.selector);
        vault.mint(20_000e18, alice);
    }

    function test_mint_emitsCanonicalDepositEvent() public {
        uint256 shares = 5_000e18;
        uint256 expectedAssets = vault.previewMint(shares);

        vm.expectEmit(true, true, false, true);
        emit Deposit(alice, alice, expectedAssets, shares);

        vm.prank(alice);
        vault.mint(shares, alice);
    }
}
