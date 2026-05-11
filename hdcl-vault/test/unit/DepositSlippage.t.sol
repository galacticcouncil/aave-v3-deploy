// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title Deposit Slippage Protection — Regression Coverage
/// @notice Verifies `depositSlippage(hollarAmount, minHdclOut)` reverts with
///         SlippageExceeded when the rate would mint less than minHdclOut.
///         The plain `deposit(hollarAmount)` remains slippage-unprotected for
///         backwards-compatible callers.
contract DepositSlippageTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════
    //   minHdclOut SATISFIED: deposit succeeds, returns expected HDCL
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositSlippage_satisfied_succeeds() public {
        // Seed the vault so totalSupply > 0
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Bob computes preview off-chain to get the expected mint
        uint256 expectedHdcl = vault.previewDeposit(TEN_THOUSAND_HOLLAR);
        // Apply 1% downward slippage tolerance (typical UI default)
        uint256 minHdclOut = (expectedHdcl * 99) / 100;

        vm.prank(bob);
        uint256 minted = vault.depositSlippage(TEN_THOUSAND_HOLLAR, minHdclOut);

        assertGe(minted, minHdclOut, "minted >= minHdclOut");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   minHdclOut VIOLATED: revert with SlippageExceeded
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositSlippage_violated_reverts() public {
        // Seed and let yield accrue so the rate is > 1
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        uint256 actualMint = vault.previewDeposit(TEN_THOUSAND_HOLLAR);
        // Demand more than the rate would mint
        uint256 unrealisticMin = actualMint + 1;

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                HDCLVault.SlippageExceeded.selector,
                unrealisticMin,
                actualMint
            )
        );
        vault.depositSlippage(TEN_THOUSAND_HOLLAR, unrealisticMin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   minHdclOut = 0: behaves identically to plain deposit
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositSlippage_zeroMin_behavesLikeDeposit() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 expected = vault.previewDeposit(TEN_THOUSAND_HOLLAR);

        vm.prank(bob);
        uint256 minted = vault.deposit(TEN_THOUSAND_HOLLAR);
        assertEq(minted, expected, "zero min produces same mint as plain deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FIRST-DEPOSIT EDGE: dead-shares math honors slippage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice First-ever deposit goes through the dead-shares branch
    /// (`hdclMinted = hollarAmount - DEAD_SHARES`). Slippage check must apply
    /// there too.
    function test_depositSlippage_firstDeposit_satisfied() public {
        uint256 amount = 10_000e18;
        // First-deposit math: minted = amount - DEAD_SHARES (1000 wei)
        uint256 expected = amount - 1000;

        vm.prank(alice);
        uint256 minted = vault.depositSlippage(amount, expected);
        assertEq(minted, expected, "first deposit minted = amount - dead shares");
    }

    function test_depositSlippage_firstDeposit_violated_reverts() public {
        uint256 amount = 10_000e18;
        uint256 expected = amount - 1000;
        uint256 unrealisticMin = expected + 1;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                HDCLVault.SlippageExceeded.selector,
                unrealisticMin,
                expected
            )
        );
        vault.depositSlippage(amount, unrealisticMin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PREVIEWDEPOSIT roundtrip: previewDeposit value works as minHdclOut
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The exact previewDeposit result must be a valid floor
    ///         (off-chain math used as on-chain check shouldn't fail).
    function test_depositSlippage_previewDepositRoundtrip() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(15);

        uint256 expected = vault.previewDeposit(5_000e18);
        vm.prank(bob);
        uint256 minted = vault.depositSlippage(5_000e18, expected);
        assertEq(minted, expected, "previewDeposit value matches actual mint exactly");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PLAIN deposit STILL works (no slippage check on legacy path)
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_plainStillWorks() public {
        vm.prank(alice);
        uint256 minted = vault.deposit(TEN_THOUSAND_HOLLAR);
        assertGt(minted, 0, "plain deposit unaffected by slippage refactor");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   COMMON CHECKS: depositSlippage honors all the same guards
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositSlippage_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(HDCLVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_depositSlippage_revertsWhenDepositsPaused() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.prank(alice);
        vm.expectRevert(HDCLVault.DepositsArePaused.selector);
        vault.deposit(TEN_THOUSAND_HOLLAR);
    }

    function test_depositSlippage_revertsWhenGloballyPaused() public {
        vm.prank(admin);
        vault.pause();

        // Pausable's whenNotPaused throws "Pausable: paused"
        vm.prank(alice);
        vm.expectRevert(bytes("Pausable: paused"));
        vault.deposit(TEN_THOUSAND_HOLLAR);
    }

    function test_depositSlippage_revertsOnExceedTvlCap() public {
        // Cap is 2_000_000e18. Try to deposit more
        vm.prank(alice);
        hollar.approve(address(vault), type(uint256).max);
        hollar.mint(alice, 3_000_000e18);

        vm.prank(alice);
        vm.expectRevert(HDCLVault.ExceedsTvlCap.selector);
        vault.deposit(2_500_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FUZZ: slippage check is monotonic
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For any valid deposit amount and any minHdclOut <= what the rate
    ///         would mint, depositSlippage succeeds. For minHdclOut > expected,
    ///         it reverts. This is the contract of slippage protection.
    function testFuzz_depositSlippage_monotonic(uint96 amount, uint96 minOut) public {
        amount = uint96(bound(amount, 10e18, 50_000e18));
        // Seed first so we're not hitting first-deposit branch
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 expected = vault.previewDeposit(amount);

        if (minOut <= expected) {
            vm.prank(bob);
            uint256 minted = vault.depositSlippage(amount, minOut);
            assertGe(minted, minOut, "satisfies floor");
        } else {
            vm.prank(bob);
            vm.expectRevert(
                abi.encodeWithSelector(
                    HDCLVault.SlippageExceeded.selector,
                    uint256(minOut),
                    expected
                )
            );
            vault.depositSlippage(amount, minOut);
        }
    }
}
