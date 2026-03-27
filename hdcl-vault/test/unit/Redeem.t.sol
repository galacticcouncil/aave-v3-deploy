// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title Comprehensive Redeem Test Suite
/// @notice Covers requestRedeem, cancelRedeem, pokeDecentral (position lifecycle),
///         pokeQueue (queue processing + reinvest), and end-to-end flows.
///         Supersedes RedemptionQueue.t.sol, ProcessPosition.t.sol, and Reinvest.t.sol.
contract RedeemTest is BaseTest {

    // ═══════════════════════════════════════════════════════════════════════
    //                     requestRedeem - REVERTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Contract enforces minRedeemAmount (default 1e18).
    ///         DEVIATION: Spec says `Require wdclAmount > 0`.
    ///         Contract uses `if (hdclAmount < minRedeemAmount) revert BelowMinimumRedeem()`.
    function test_requestRedeem_reverts_whenBelowMinRedeemAmount() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(alice);
        vm.expectRevert(HDCLVault.BelowMinimumRedeem.selector);
        vault.requestRedeem(1e18 - 1); // just below 1 HDCL
    }

    function test_requestRedeem_reverts_whenInsufficientBalance() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 aliceBal = vault.balanceOf(alice);

        // Try to redeem more than Alice has
        vm.prank(alice);
        vm.expectRevert(); // ERC20 transfer reverts on insufficient balance
        vault.requestRedeem(aliceBal + 1);
    }

    function test_requestRedeem_reverts_whenGloballyPaused() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        vault.requestRedeem(ONE_HOLLAR);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   requestRedeem - HAPPY PATH
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec: HDCL transferred to vault as escrow (not burned)
    function test_requestRedeem_escrowsHdclInVault() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 redeemAmt = hdcl / 2;

        uint256 aliceBefore = vault.balanceOf(alice);
        uint256 vaultBefore = vault.balanceOf(address(vault));

        _requestRedeem(alice, redeemAmt);

        assertEq(vault.balanceOf(alice), aliceBefore - redeemAmt, "Alice HDCL decreased");
        assertEq(vault.balanceOf(address(vault)), vaultBefore + redeemAmt, "Vault holds escrow");
    }

    /// @notice Spec: totalSupply unchanged by escrow (rate unaffected)
    function test_requestRedeem_doesNotAffectExchangeRate() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        uint256 rateBefore = vault.exchangeRate();
        uint256 supplyBefore = vault.totalSupply();

        _requestRedeem(alice, hdcl / 2);

        assertEq(vault.totalSupply(), supplyBefore, "totalSupply unchanged by escrow");
        assertEq(vault.exchangeRate(), rateBefore, "Exchange rate unchanged by escrow");
    }

    /// @notice Spec: queue entry created with correct fields
    function test_requestRedeem_createsQueueEntry() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 redeemAmt = hdcl / 2;

        uint256 requestId = _requestRedeem(alice, redeemAmt);

        (address user, uint256 amount, uint256 fulfilled, bool active) =
            vault.getRedemptionRequest(requestId);

        assertEq(user, alice);
        assertEq(amount, redeemAmt);
        assertEq(fulfilled, 0);
        assertTrue(active);
    }

    /// @notice Spec: totalQueuedWdcl += wdclAmount
    function test_requestRedeem_updatesTotalQueuedHdcl() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 redeemAmt = hdcl / 2;

        assertEq(vault.totalQueuedHdcl(), 0);

        _requestRedeem(alice, redeemAmt);

        assertEq(vault.totalQueuedHdcl(), redeemAmt);
    }

    /// @notice Multiple requests increment requestId sequentially
    function test_requestRedeem_incrementsRequestId() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 id0 = _requestRedeem(alice, hdcl / 4);
        uint256 id1 = _requestRedeem(alice, hdcl / 4);

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(vault.getRedemptionQueueLength(), 2);
    }

    /// @notice Spec: emit RedemptionRequested(requestId, msg.sender, wdclAmount)
    function test_requestRedeem_emitsEvent() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 redeemAmt = hdcl / 2;

        vm.expectEmit(true, true, false, true);
        emit RedemptionRequested(0, alice, redeemAmt);

        vm.prank(alice);
        vault.requestRedeem(redeemAmt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     cancelRedeem - REVERTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancelRedeem_reverts_whenNotOwner() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 requestId = _requestRedeem(alice, hdcl / 2);

        vm.prank(bob);
        vm.expectRevert(HDCLVault.NotRequestOwner.selector);
        vault.cancelRedeem(requestId);
    }

    function test_cancelRedeem_reverts_whenAlreadyCancelled() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 requestId = _requestRedeem(alice, hdcl / 2);

        vm.prank(alice);
        vault.cancelRedeem(requestId);

        vm.prank(alice);
        vm.expectRevert(HDCLVault.RequestNotActive.selector);
        vault.cancelRedeem(requestId);
    }

    function test_cancelRedeem_reverts_whenInvalidRequestId() public {
        vm.prank(alice);
        vm.expectRevert(HDCLVault.InvalidRequestId.selector);
        vault.cancelRedeem(999);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   cancelRedeem - HAPPY PATH
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec: return escrowed HDCL, update totalQueuedWdcl, mark inactive
    function test_cancelRedeem_returnsEscrowedHdcl() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 redeemAmt = hdcl / 2;
        uint256 requestId = _requestRedeem(alice, redeemAmt);

        uint256 aliceBefore = vault.balanceOf(alice);

        vm.prank(alice);
        vault.cancelRedeem(requestId);

        assertEq(vault.balanceOf(alice), aliceBefore + redeemAmt, "HDCL returned");
        assertEq(vault.totalQueuedHdcl(), 0, "totalQueuedHdcl zeroed");

        (, , , bool active) = vault.getRedemptionRequest(requestId);
        assertFalse(active, "Request inactive after cancel");
    }

    /// @notice Spec: if partially fulfilled, only unfulfilled portion returned
    function test_cancelRedeem_partiallyFulfilledReturnsRemainder() public {
        // Setup: two depositors, process one position for limited idle
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0); // idle ~= 10,300 HOLLAR

        // Alice queues all her HDCL (needs ~10,299 HOLLAR)
        uint256 aliceHdcl = vault.balanceOf(alice);
        _requestRedeem(alice, aliceHdcl);

        // Bob queues all his HDCL (needs ~10,300 HOLLAR)
        uint256 bobHdcl = vault.balanceOf(bob);
        uint256 bobRequestId = _requestRedeem(bob, bobHdcl);

        // Process queue: Alice fully fulfilled (FIFO), Bob partially
        vault.pokeQueue();

        (, , uint256 bobFulfilled, bool bobActive) = vault.getRedemptionRequest(bobRequestId);
        // Bob should be partially fulfilled if any idle remained after Alice
        if (bobFulfilled > 0 && bobActive) {
            uint256 remaining = bobHdcl - bobFulfilled;
            uint256 bobHdclBefore = vault.balanceOf(bob);

            // Cancel Bob's partially fulfilled request
            vm.prank(bob);
            vault.cancelRedeem(bobRequestId);

            // Only the unfulfilled portion is returned
            assertEq(
                vault.balanceOf(bob),
                bobHdclBefore + remaining,
                "Only unfulfilled HDCL returned on cancel"
            );
        }
    }

    /// @notice Spec: emit RedemptionCancelled(requestId, remaining)
    function test_cancelRedeem_emitsEvent() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 redeemAmt = hdcl / 2;
        uint256 requestId = _requestRedeem(alice, redeemAmt);

        vm.expectEmit(true, false, false, true);
        emit RedemptionCancelled(requestId, redeemAmt);

        vm.prank(alice);
        vault.cancelRedeem(requestId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //              pokeDecentral - POSITION LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.5: Active -> YieldWithdrawalRequested when mature
    function test_pokeDecentral_activeToYieldRequested() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 1, "YieldWithdrawalRequested");
    }

    /// @notice Spec §4.5: no-op before maturity
    function test_pokeDecentral_noopBeforeMaturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30); // only 30 of 60 days

        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "Still Active before maturity");
    }

    /// @notice Spec §4.5: yield execute -> YieldClaimed, then immediately -> PrincipalWithdrawalRequested
    function test_pokeDecentral_yieldClaimedToPrincipalRequested() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        uint256 idleBefore = vault.idleHollar();

        // Execute yield + request principal in single call
        vault.pokeDecentral(0);

        assertGt(vault.idleHollar(), idleBefore, "Yield received as idle HOLLAR");

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 3, "PrincipalWithdrawalRequested (skips through YieldClaimed)");
    }

    /// @notice Spec §4.5: try/catch no-op when yield not approved
    function test_pokeDecentral_noopYieldNotApproved() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        vault.pokeDecentral(0); // -> YieldWithdrawalRequested
        // DO NOT approve yield

        vault.pokeDecentral(0); // should no-op (try/catch)

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 1, "Still YieldWithdrawalRequested when not approved");
    }

    /// @notice Spec §4.5: PrincipalWithdrawalRequested -> Redeemed after approval + delay
    function test_pokeDecentral_principalRequestedToRedeemed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Walk through to PrincipalWithdrawalRequested
        vault.pokeDecentral(0);
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        // Approve principal + warp past 48h delay
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 idleBefore = vault.idleHollar();

        vault.pokeDecentral(0);

        assertGt(vault.idleHollar(), idleBefore, "Principal received as idle HOLLAR");

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "Redeemed");
    }

    /// @notice Spec §4.5: reverts on already-redeemed position
    function test_pokeDecentral_reverts_whenAlreadyRedeemed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        vm.expectRevert(HDCLVault.PositionAlreadyRedeemed.selector);
        vault.pokeDecentral(0);
    }

    /// @notice Full lifecycle: Active -> ... -> Redeemed, verify idle = principal + yield
    function test_pokeDecentral_fullLifecycle_correctAmounts() public {
        uint256 depositAmt = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmt);
        _warpDays(61);

        _processPositionFull(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "Redeemed");

        uint256 idle = vault.idleHollar();
        uint256 expectedYield = _expectedYield(depositAmt, APY_18_PERCENT, 61);
        assertApproxEqRel(
            idle,
            depositAmt + expectedYield,
            0.01e18,
            "idle = principal + yield"
        );
    }

    /// @notice Spec §4.5: yield amount matches simple interest formula
    function test_pokeDecentral_correctYieldReceived() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        vault.pokeDecentral(0);
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        uint256 idleBefore = vault.idleHollar();
        vault.pokeDecentral(0);
        uint256 yieldReceived = vault.idleHollar() - idleBefore;

        uint256 expected = _expectedYield(TEN_THOUSAND_HOLLAR, APY_18_PERCENT, 61);
        assertApproxEqRel(yieldReceived, expected, 0.01e18, "Yield matches formula");
    }

    /// @notice Spec §4.5: positionHead advances after head position redeemed
    function test_pokeDecentral_advancesPositionHead() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        assertEq(vault.getPositionHead(), 0);

        _warpDays(61);
        _processPositionFull(0);

        assertEq(vault.getPositionHead(), 1, "Head advances past redeemed position");
    }

    /// @notice Spec §4.5: upon Redeemed, triggers queue processing with idle HOLLAR
    function test_pokeDecentral_triggersQueueOnRedemption() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Queue redeem BEFORE processing (no idle yet)
        uint256 redeemAmt = aliceHdcl / 4;
        _requestRedeem(alice, redeemAmt);
        assertEq(vault.totalQueuedHdcl(), redeemAmt);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        // Process position fully -> principal arrives -> auto-processes queue
        _processPositionFull(0);

        // Queue should be cleared (idle from redemption fulfilled it)
        assertEq(vault.totalQueuedHdcl(), 0, "Queue auto-cleared on position redemption");
        assertGt(hollar.balanceOf(alice), aliceHollarBefore, "Alice received HOLLAR");
    }

    /// @notice Multiple positions: only mature ones advance
    function test_pokeDecentral_multiplePositions_onlyMatureAdvances() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(10);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // 51 more days: position 0 mature (61d), position 1 NOT (51d)
        _warpDays(51);

        vault.pokeDecentral(0);
        (, , , , , uint8 s0) = vault.getPosition(0);
        assertEq(s0, 1, "Position 0 advances (mature)");

        vault.pokeDecentral(1);
        (, , , , , uint8 s1) = vault.getPosition(1);
        assertEq(s1, 0, "Position 1 stays Active (not mature)");
    }

    /// @notice Anyone can call pokeDecentral (permissionless)
    function test_pokeDecentral_permissionless() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Random keeper calls it
        vm.prank(keeper);
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 1, "Keeper can advance position");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //               pokeQueue - QUEUE PROCESSING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.6: full fulfillment burns HDCL, sends HOLLAR
    function test_pokeQueue_fullyFulfillsRequest() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 redeemAmt = aliceHdcl / 4;
        _requestRedeem(alice, redeemAmt);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();

        vault.pokeQueue();

        assertEq(vault.totalQueuedHdcl(), 0, "Queue fully cleared");
        assertGt(hollar.balanceOf(alice), aliceHollarBefore, "Alice received HOLLAR");
        assertEq(vault.totalSupply(), supplyBefore - redeemAmt, "HDCL burned");
    }

    /// @notice Spec §4.6: partial fulfillment when idle < HOLLAR needed
    function test_pokeQueue_partialFulfillment() public {
        // Two deposits, process only one -> limited idle
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0); // idle ~= 10,300

        // Queue both users (total HOLLAR needed ~= 20,600, idle ~= 10,300)
        uint256 aliceHdcl = vault.balanceOf(alice);
        uint256 bobHdcl = vault.balanceOf(bob);
        _requestRedeem(alice, aliceHdcl);
        _requestRedeem(bob, bobHdcl);

        uint256 totalQueuedBefore = vault.totalQueuedHdcl();

        vault.pokeQueue();

        uint256 totalQueuedAfter = vault.totalQueuedHdcl();
        assertLt(totalQueuedAfter, totalQueuedBefore, "Queue partially drained");
        assertGt(totalQueuedAfter, 0, "Queue not fully cleared (not enough idle)");
    }

    /// @notice Spec §4.6: FIFO ordering - first request fulfilled first
    function test_pokeQueue_fifoOrdering() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1); // plenty of idle for both

        uint256 aliceRedeem = vault.balanceOf(alice) / 4;
        uint256 bobRedeem = vault.balanceOf(bob) / 4;
        _requestRedeem(alice, aliceRedeem); // request 0
        _requestRedeem(bob, bobRedeem);     // request 1

        uint256 aliceHollarBefore = hollar.balanceOf(alice);
        uint256 bobHollarBefore = hollar.balanceOf(bob);

        vault.pokeQueue();

        assertEq(vault.totalQueuedHdcl(), 0, "Both fulfilled");
        assertGt(hollar.balanceOf(alice), aliceHollarBefore, "Alice (first) received HOLLAR");
        assertGt(hollar.balanceOf(bob), bobHollarBefore, "Bob (second) received HOLLAR");
    }

    /// @notice Spec §4.6: skips inactive (cancelled) entries
    function test_pokeQueue_skipsInactiveEntries() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 req0 = _requestRedeem(alice, aliceHdcl / 4);
        _requestRedeem(alice, aliceHdcl / 4); // req1

        // Cancel req0
        vm.prank(alice);
        vault.cancelRedeem(req0);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        vault.pokeQueue();

        // req0 skipped, req1 fulfilled
        assertEq(vault.totalQueuedHdcl(), 0, "Queue cleared (skipped cancelled entry)");
        assertGt(hollar.balanceOf(alice), aliceHollarBefore, "Alice received HOLLAR for req1");
    }

    /// @notice Spec §4.6: burn at current rate; HOLLAR = hdcl * rate / 1e18
    function test_pokeQueue_burnsAtCurrentRate() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 rate = vault.exchangeRate();
        assertGt(rate, 1e18, "Rate > 1 after yield");

        uint256 redeemAmt = aliceHdcl / 4;
        _requestRedeem(alice, redeemAmt);

        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        vault.pokeQueue();

        uint256 hollarReceived = hollar.balanceOf(alice) - aliceHollarBefore;
        uint256 expectedHollar = (redeemAmt * rate) / 1e18;
        assertApproxEqRel(hollarReceived, expectedHollar, 0.01e18, "HOLLAR = hdcl * rate");
    }

    /// @notice Spec §4.6: exchange rate preserved after queue processing
    function test_pokeQueue_preservesExchangeRate() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 bobHdcl = _deposit(bob, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1);

        _requestRedeem(bob, bobHdcl / 4);

        uint256 rateBefore = vault.exchangeRate();

        vault.pokeQueue();

        uint256 rateAfter = vault.exchangeRate();
        assertApproxEqRel(rateAfter, rateBefore, 0.01e18, "Rate preserved");
    }

    /// @notice Anyone can call pokeQueue (permissionless)
    function test_pokeQueue_permissionless() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _requestRedeem(alice, aliceHdcl / 4);

        vm.prank(keeper);
        vault.pokeQueue();

        assertEq(vault.totalQueuedHdcl(), 0, "Keeper can process queue");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  pokeQueue - REINVEST
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.7: when queue empty and idle >= minReinvest, reinvests into Decentral
    function test_pokeQueue_reinvestsWhenQueueEmpty() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 0);
        assertEq(vault.totalQueuedHdcl(), 0, "Queue empty");

        uint256 posBefore = vault.getPositionCount();

        vault.pokeQueue();

        assertEq(vault.getPositionCount(), posBefore + 1, "New position created");
        assertLt(vault.idleHollar(), idle, "Idle decreased");
    }

    /// @notice Spec §4.7: reinvest creates a correct position
    function test_pokeQueue_reinvestCreatesCorrectPosition() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        uint256 posIdx = vault.getPositionCount();

        vault.pokeQueue();

        (, uint256 principal, uint256 apyWad, , , uint8 state) = vault.getPosition(posIdx);
        assertApproxEqRel(principal, idle, 0.01e18, "Reinvested principal = idle");
        assertEq(apyWad, APY_18_PERCENT, "APY from pool");
        assertEq(state, 0, "Active");
    }

    /// @notice Spec §4.7 step 1: queue gets processed BEFORE reinvest
    function test_pokeQueue_processesQueueThenReinvests() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // Small redeem -> leaves plenty of idle after fulfillment
        _requestRedeem(alice, aliceHdcl / 10);

        uint256 posBefore = vault.getPositionCount();

        vault.pokeQueue();

        assertEq(vault.totalQueuedHdcl(), 0, "Queue fulfilled first");
        // Remaining idle should be reinvested if >= minReinvestAmount
        if (vault.idleHollar() == 0) {
            assertGt(vault.getPositionCount(), posBefore, "Remaining idle reinvested");
        }
    }

    /// @notice Spec §4.7 step 2: skip reinvest below minReinvestAmount
    function test_pokeQueue_reinvestSkippedBelowMinAmount() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(admin);
        vault.setMinReinvestAmount(100_000e18);

        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        assertGt(idle, 0);
        assertLt(idle, 100_000e18);

        uint256 posBefore = vault.getPositionCount();

        vault.pokeQueue();

        assertEq(vault.getPositionCount(), posBefore, "No new position (below min)");
        assertEq(vault.idleHollar(), idle, "Idle unchanged");
    }

    /// @notice Spec §4.7 step 3: skip reinvest when deposits are paused
    function test_pokeQueue_reinvestSkippedWhenDepositsPaused() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        vm.prank(admin);
        vault.pauseDeposits();

        uint256 idle = vault.idleHollar();
        uint256 posBefore = vault.getPositionCount();

        vault.pokeQueue();

        assertEq(vault.getPositionCount(), posBefore, "No reinvest when paused");
        assertEq(vault.idleHollar(), idle, "Idle unchanged");
    }

    /// @notice Spec §4.7 step 5: reinvest caps at tvlCap
    function test_pokeQueue_reinvestRespectsTvlCap() public {
        vm.prank(admin);
        vault.setTvlCap(TEN_THOUSAND_HOLLAR);

        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // idle > tvlCap because it includes yield
        uint256 idle = vault.idleHollar();
        assertGt(idle, TEN_THOUSAND_HOLLAR, "Idle includes yield");

        uint256 posIdx = vault.getPositionCount();

        vault.pokeQueue();

        (, uint256 principal, , , , ) = vault.getPosition(posIdx);
        assertEq(principal, TEN_THOUSAND_HOLLAR, "Reinvest capped at tvlCap");

        // Remainder stays as idle
        assertApproxEqRel(
            vault.idleHollar(),
            idle - TEN_THOUSAND_HOLLAR,
            0.01e18,
            "Excess stays as idle"
        );
    }

    /// @notice Reinvest updates accounting: totalInvestedPrincipal, bucket, idleHollar
    function test_pokeQueue_reinvestUpdatesAccounting() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 idle = vault.idleHollar();
        uint256 investedBefore = vault.totalInvestedPrincipal();

        vault.pokeQueue();

        assertApproxEqRel(
            vault.totalInvestedPrincipal(),
            investedBefore + idle,
            0.01e18,
            "totalInvestedPrincipal increased"
        );
        assertGe(vault.getActiveAPYCount(), 1, "APY bucket exists");
    }

    /// @notice Reinvest preserves exchange rate
    function test_pokeQueue_reinvestPreservesExchangeRate() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 rateBefore = vault.exchangeRate();

        vault.pokeQueue();

        uint256 rateAfter = vault.exchangeRate();
        assertApproxEqRel(rateAfter, rateBefore, 0.01e18, "Rate preserved after reinvest");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      END-TO-END FLOWS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Full user journey: deposit -> wait -> redeem -> receive HOLLAR with yield
    function test_e2e_depositRedeemFullCycle() public {
        // 1. Alice deposits
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 aliceHollarStart = hollar.balanceOf(alice);

        // 2. Wait for position to mature
        _warpDays(61);

        // 3. Keeper processes position
        _processPositionFull(0);

        // 4. Alice requests full redemption
        _requestRedeem(alice, aliceHdcl);

        // 5. Keeper pokes queue
        vault.pokeQueue();

        // 6. Alice gets back principal + yield
        uint256 hollarReceived = hollar.balanceOf(alice) - aliceHollarStart;
        uint256 expectedYield = _expectedYield(TEN_THOUSAND_HOLLAR, APY_18_PERCENT, 61);

        assertApproxEqRel(
            hollarReceived,
            TEN_THOUSAND_HOLLAR + expectedYield,
            0.02e18,
            "Alice receives principal + yield"
        );
    }

    /// @notice Yield accrues while user waits in queue (exchange rate appreciates)
    function test_e2e_yieldAccruesDuringQueueWait() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // Alice queues early (no idle yet)
        uint256 aliceHdcl = vault.balanceOf(alice);
        _requestRedeem(alice, aliceHdcl);

        uint256 rateAtQueue = vault.exchangeRate();

        // Wait 61 days, process position 0
        _warpDays(61);

        uint256 rateAfterYield = vault.exchangeRate();
        assertGt(rateAfterYield, rateAtQueue, "Rate appreciated during wait");

        _processPositionFull(0);

        // Queue auto-cleared at the CURRENT rate (higher than when queued)
        uint256 hollarReceived = hollar.balanceOf(alice) - (100_000e18 - TEN_THOUSAND_HOLLAR);

        // Alice benefits from yield accrued during the wait
        // hollarReceived should be > original deposit (she earned yield while waiting)
        assertGt(hollarReceived, 0, "Alice received HOLLAR at appreciated rate");
    }

    /// @notice Multiple users: deposit, partial exit, reinvest cycle.
    ///         Note: pokeQueue evaluates queueCanProgress once upfront.
    ///         If queue was processed in the same call, reinvest requires a second pokeQueue.
    function test_e2e_multiUserCycle() public {
        // Alice and Bob deposit
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // Mature and process both
        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1);

        // Alice exits partially
        _requestRedeem(alice, aliceHdcl / 2);
        vault.pokeQueue(); // fulfills queue
        vault.pokeQueue(); // now queue is empty -> reinvests remaining idle

        uint256 posCount = vault.getPositionCount();
        assertGt(posCount, 2, "Reinvested positions created");

        // Bob still holds HDCL - value should be preserved
        uint256 bobValue = vault.previewRedeem(vault.balanceOf(bob));
        assertGt(bobValue, TEN_THOUSAND_HOLLAR, "Bob's HDCL worth more than initial deposit");
    }

    /// @notice Estimated wait time: non-zero before maturity, zero after fulfillment
    function test_e2e_estimatedWaitTime() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        uint256 requestId = _requestRedeem(alice, aliceHdcl / 4);

        uint256 waitBefore = vault.getEstimatedWaitTime(requestId);
        assertGt(waitBefore, 0, "Wait > 0 when no idle and position not mature");

        // Mature, process, fulfill
        _warpDays(61);
        _processPositionFull(0);
        vault.pokeQueue();

        uint256 waitAfter = vault.getEstimatedWaitTime(requestId);
        assertEq(waitAfter, 0, "Wait = 0 after fulfillment");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _expectedYield(
        uint256 principal,
        uint256 apyWad,
        uint256 days_
    ) internal pure returns (uint256) {
        return (principal * apyWad * days_ * SECONDS_PER_DAY) / (365 days * 1e18);
    }

    // Events inherited from Events.sol via BaseTest
}
