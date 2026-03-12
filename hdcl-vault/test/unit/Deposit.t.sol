// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

contract DepositTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════
    //                      FIRST DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_firstDeposit_1to1Rate() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        uint256 hdcl = _deposit(alice, depositAmount);

        // First deposit mints at 1:1 minus dead shares (1000 wei)
        assertEq(hdcl, depositAmount - 1000);
        assertEq(vault.balanceOf(alice), depositAmount - 1000);
    }

    function test_firstDeposit_deadSharesMinted() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 1000 dead shares sent to 0xdead
        assertEq(vault.balanceOf(address(0xdead)), 1000);
    }

    function test_secondDeposit_correctRate() public {
        // Alice deposits first
        uint256 aliceDeposit = TEN_THOUSAND_HOLLAR;
        _deposit(alice, aliceDeposit);

        // Warp 30 days -- yield accrues, pushing exchange rate above 1:1
        _warpDays(30);

        uint256 rateBefore = vault.exchangeRate();
        assertGt(rateBefore, 1e18, "Rate should be > 1 after 30 days of yield");

        // Bob deposits -- should get fewer HDCL than his HOLLAR amount
        uint256 bobDeposit = TEN_THOUSAND_HOLLAR;
        uint256 bobHdcl = _deposit(bob, bobDeposit);

        // Manual calculation: hdclMinted = hollarAmount * totalSupply / totalAssets
        uint256 totalSupplyBefore = vault.totalSupply() - bobHdcl; // supply before Bob's mint
        uint256 totalAssetsBefore = aliceDeposit + _expectedYield(aliceDeposit, APY_18_PERCENT, 30);

        uint256 expectedBobHdcl = bobDeposit * totalSupplyBefore / totalAssetsBefore;
        assertApproxEqRel(bobHdcl, expectedBobHdcl, 0.01e18, "Bob HDCL should match expected at current rate");

        // Bob should get fewer HDCL than HOLLAR deposited
        assertLt(bobHdcl, bobDeposit, "HDCL minted should be less than HOLLAR at rate > 1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    POSITION & BUCKET TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_createsNFTPosition() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionCount(), 1, "Should have 1 position");

        (
            uint256 tokenId,
            uint256 principal,
            uint256 apyWad,
            uint256 depositTime,
            uint256 maturityTime,
            uint8 state
        ) = vault.getPosition(0);

        assertGt(tokenId, 0, "Token ID should be > 0");
        assertEq(principal, TEN_THOUSAND_HOLLAR, "Principal should match deposit");
        assertEq(apyWad, APY_18_PERCENT, "APY should match pool APY");
        assertEq(depositTime, block.timestamp, "Deposit time should be now");
        assertEq(maturityTime, block.timestamp + SIXTY_DAYS, "Maturity should be 60 days out");
        assertEq(state, 0, "State should be Active (0)");
    }

    function test_deposit_updatesAPYBucket() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getActiveAPYCount(), 1, "Should have 1 active APY");
        assertEq(vault.getActiveAPY(0), APY_18_PERCENT, "Active APY should be 18%");
        assertEq(vault.totalInvestedPrincipal(), TEN_THOUSAND_HOLLAR, "Invested principal should match");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    QUEUE CLEARING TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_clearsQueueFirst() public {
        // 1. Alice deposits to create a position
        uint256 aliceDeposit = TEN_THOUSAND_HOLLAR;
        uint256 aliceHdcl = _deposit(alice, aliceDeposit);

        // 2. Warp past maturity (60+ days)
        _warpDays(61);

        // 3. Process position fully -- principal + yield return to idleHollar
        _processPositionFull(0);

        uint256 idleAfterProcess = vault.idleHollar();
        assertGt(idleAfterProcess, 0, "Should have idle HOLLAR after position processing");

        // 4. Alice requests redemption -- enters the queue
        uint256 redeemAmount = aliceHdcl / 2;
        _requestRedeem(alice, redeemAmount);
        assertEq(vault.totalQueuedHdcl(), redeemAmount, "Queue should have Alice's request");

        // 5. Bob deposits -- should clear Alice's queue entry using idleHollar
        uint256 bobDeposit = TEN_THOUSAND_HOLLAR;
        uint256 aliceHollarBefore = hollar.balanceOf(alice);
        _deposit(bob, bobDeposit);

        // Queue should be empty after Bob's deposit cleared it
        assertEq(vault.totalQueuedHdcl(), 0, "Queue should be cleared after Bob's deposit");

        // Alice should have received HOLLAR from the queue fulfillment
        uint256 aliceHollarAfter = hollar.balanceOf(alice);
        assertGt(aliceHollarAfter, aliceHollarBefore, "Alice should have received HOLLAR from queue");
    }

    function test_deposit_partialQueueClear() public {
        // 1. Alice deposits
        uint256 aliceDeposit = TEN_THOUSAND_HOLLAR;
        uint256 aliceHdcl = _deposit(alice, aliceDeposit);

        // 2. Warp past maturity and process position
        _warpDays(61);
        _processPositionFull(0);

        // 3. Alice requests a large redemption
        _requestRedeem(alice, aliceHdcl);

        // 4. Bob deposits a small amount -- partial queue clear
        //    The amount of idleHollar available determines how much queue gets cleared.
        //    Bob's deposit of a small amount won't fully clear a large queue.
        uint256 smallBobDeposit = HUNDRED_HOLLAR;
        _deposit(bob, smallBobDeposit);

        // Queue should still have remaining HDCL
        assertGt(vault.totalQueuedHdcl(), 0, "Queue should still have pending HDCL");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    IDLE HOLLAR / MIN REINVEST
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_remainderBelowMinReinvest() public {
        // First, do a normal deposit so we're past the dead-shares branch
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // minReinvestAmount defaults to 10e18 (10 HOLLAR)
        // Deposit less than minReinvestAmount: the deposit goes to idleHollar
        uint256 smallDeposit = 5e18; // 5 HOLLAR
        _deposit(bob, smallDeposit);

        // The small deposit should go to idleHollar instead of creating a new position
        assertGt(vault.idleHollar(), 0, "Idle HOLLAR should increase for sub-minReinvest deposit");
        // Only 1 position from Alice's deposit
        assertEq(vault.getPositionCount(), 1, "Should still have just 1 position");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          REVERT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_reverts_whenPaused() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.expectRevert(HDCLVault.DepositsArePaused.selector);
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    function test_deposit_reverts_whenTvlCapExceeded() public {
        // Set a tiny TVL cap
        vm.prank(admin);
        vault.setTvlCap(HUNDRED_HOLLAR);

        // Deposit more than the cap
        vm.expectRevert(HDCLVault.ExceedsTvlCap.selector);
        _deposit(alice, HUNDRED_HOLLAR + ONE_HOLLAR);
    }

    function test_deposit_reverts_whenZeroAmount() public {
        vm.expectRevert(HDCLVault.ZeroAmount.selector);
        _deposit(alice, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    EXCHANGE RATE PRESERVATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_preservesExchangeRate() public {
        // First deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp so rate diverges from 1:1
        _warpDays(30);

        uint256 rateBefore = vault.exchangeRate();

        // Second deposit should not change the exchange rate
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        uint256 rateAfter = vault.exchangeRate();

        // Rate should be approximately the same (within 0.01% for rounding)
        assertApproxEqRel(rateBefore, rateAfter, 0.0001e18, "Exchange rate should be preserved after deposit");
    }

    function test_deposit_multipleDeposits_cumulativePrincipal() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.totalInvestedPrincipal(), 2 * TEN_THOUSAND_HOLLAR, "Total principal should be sum of deposits");
        assertEq(vault.getPositionCount(), 2, "Should have 2 positions");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Calculate expected yield: principal * apyWad * days / 365 / 1e18
    function _expectedYield(uint256 principal, uint256 apyWad, uint256 days_)
        internal
        pure
        returns (uint256)
    {
        return principal * apyWad * days_ * SECONDS_PER_DAY / (365 days * 1e18);
    }
}
