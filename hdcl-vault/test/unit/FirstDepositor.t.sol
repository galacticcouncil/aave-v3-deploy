// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

contract FirstDepositorTest is BaseTest {
    address public attacker = makeAddr("attacker");
    address public victim = makeAddr("victim");

    uint256 constant DEAD_SHARES = 1000;
    address constant DEAD_ADDRESS = address(0xdead);

    function setUp() public override {
        super.setUp();
        // Fund attacker and victim
        hollar.mint(attacker, 100_000e18);
        hollar.mint(victim, 100_000e18);
        vm.prank(attacker);
        hollar.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        hollar.approve(address(vault), type(uint256).max);
    }

    /// @notice Classic inflation attack: attacker deposits minimum, donates large amount,
    ///         then second depositor loses value. With idleHollar tracking (not balanceOf),
    ///         the donation does NOT inflate the exchange rate, so victim gets fair shares.
    function test_inflationAttack_mitigated() public {
        // Step 1: Attacker makes the first deposit (must be >= minReinvestAmount = 10e18)
        //         The vault will mint (amount - DEAD_SHARES) to attacker, DEAD_SHARES to 0xdead
        uint256 attackerDeposit = 10e18;
        vm.prank(attacker);
        uint256 attackerBil = vault.deposit(attackerDeposit, attacker);

        // Attacker got (10e18 - 1000) BIL
        assertEq(attackerBil, attackerDeposit - DEAD_SHARES, "attacker should get deposit - dead shares");

        // Dead shares were minted to 0xdead
        assertEq(vault.balanceOf(DEAD_ADDRESS), DEAD_SHARES, "dead shares should go to 0xdead");

        // Step 2: Attacker donates a large amount of HOLLAR directly to the vault contract.
        //         Since the vault tracks idleHollar via state (not balanceOf), this donation
        //         should NOT affect totalAssets() and therefore NOT inflate the exchange rate.
        uint256 donationAmount = 1_000e18;
        vm.prank(attacker);
        hollar.transfer(address(vault), donationAmount);

        // Verify the exchange rate is NOT inflated by the donation
        //   totalAssets should still be ~10e18 (the actual deposited amount in the pool)
        //   The donated 1000e18 sitting in the contract is invisible to totalAssets()
        uint256 rateAfterDonation = vault.exchangeRate();

        // Rate should be very close to 1e18 (no time has passed for yield accrual)
        // It is totalAssets() * 1e18 / totalSupply()
        // totalAssets() = totalInvestedPrincipal (10e18) + accruedYield (0) + idleHollar (0) + staleValue (0)
        // totalSupply() = 10e18 (attacker shares + dead shares)
        assertEq(rateAfterDonation, 1e18, "exchange rate should be 1:1 - donation has no effect");

        // Step 3: Victim deposits 10e18 HOLLAR
        uint256 victimDeposit = 10e18;
        vm.prank(victim);
        uint256 victimBil = vault.deposit(victimDeposit, victim);

        // Victim should receive ~ victimDeposit * supply / totalAssets = 10e18 * 10e18 / 10e18 = 10e18 BIL
        // (fair amount, NOT rounded down to zero by the inflated rate)
        assertEq(victimBil, victimDeposit, "victim should receive fair BIL amount despite donation attack");
    }

    /// @notice After a large first deposit, a second depositor receives proportional BIL.
    function test_smallDeposit_afterLargeFirst() public {
        // Alice makes a large first deposit
        uint256 largeDeposit = 50_000e18;
        vm.prank(alice);
        uint256 aliceBil = vault.deposit(largeDeposit, alice);
        assertEq(aliceBil, largeDeposit - DEAD_SHARES, "first depositor gets amount - dead shares");

        // Warp 30 days so some yield accrues (rate > 1)
        _warpDays(30);

        uint256 rateBefore = vault.exchangeRate();
        assertGt(rateBefore, 1e18, "rate should have appreciated");

        // Bob makes a smaller deposit
        uint256 smallDeposit = 1_000e18;
        vm.prank(bob);
        uint256 bobBil = vault.deposit(smallDeposit, bob);

        // Bob should receive proportional BIL at the current rate:
        //   bobBil = smallDeposit * totalSupplyBefore / totalAssetsBefore
        //   Since rate > 1, bobBil < smallDeposit
        assertGt(bobBil, 0, "bob should receive non-zero BIL");
        assertLt(bobBil, smallDeposit, "bob should receive less BIL than HOLLAR deposited since rate > 1");

        // Verify proportionality: bob's HOLLAR value should be close to his deposit
        uint256 bobHollarValue = bobBil * vault.exchangeRate() / 1e18;
        // Allow 1% tolerance for rounding
        assertApproxEqRel(bobHollarValue, smallDeposit, 0.01e18, "bob's BIL value should approximate his deposit");
    }

    /// @notice Verify dead shares are minted to the DEAD_ADDRESS on first deposit.
    function test_deadShares_sentToDeadAddress() public {
        assertEq(vault.totalSupply(), 0, "no supply before first deposit");
        assertEq(vault.balanceOf(DEAD_ADDRESS), 0, "no dead shares before first deposit");

        // First deposit
        uint256 depositAmount = 1_000e18;
        vm.prank(alice);
        uint256 aliceBil = vault.deposit(depositAmount, alice);

        // Dead shares minted to DEAD_ADDRESS
        assertEq(vault.balanceOf(DEAD_ADDRESS), DEAD_SHARES, "dead shares should be minted to 0xdead");

        // Alice receives (deposit - dead shares)
        assertEq(aliceBil, depositAmount - DEAD_SHARES, "first depositor gets deposit minus dead shares");

        // Total supply = alice + dead
        assertEq(vault.totalSupply(), depositAmount, "total supply should equal full deposit amount");

        // Second deposit should NOT mint additional dead shares
        vm.prank(bob);
        uint256 bobBil = vault.deposit(1_000e18, bob);
        assertGt(bobBil, 0, "bob gets BIL");
        assertEq(vault.balanceOf(DEAD_ADDRESS), DEAD_SHARES, "dead shares should NOT increase on second deposit");
    }
}
