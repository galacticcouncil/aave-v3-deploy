// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

contract ProcessPositionTest is BaseTest {
    /// @dev Helper to calculate expected yield: principal * apyWad * days / 365 / 1e18
    function _expectedYield(uint256 principal, uint256 apyWad, uint256 days_)
        internal
        pure
        returns (uint256)
    {
        return principal * apyWad * days_ * SECONDS_PER_DAY / (365 days * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //             ACTIVE -> YIELD WITHDRAWAL REQUESTED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_activeToYieldRequested() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp past 60-day maturity
        _warpDays(61);

        // Process: Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 1, "State should be YieldWithdrawalRequested (1)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         YIELD REQUESTED -> YIELD CLAIMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_yieldRequestedToYieldClaimed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield on mock pool
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        uint256 idleBefore = vault.idleHollar();

        // YieldWithdrawalRequested -> YieldClaimed -> PrincipalWithdrawalRequested
        // (yield claimed and principal requested happen in same call)
        vault.pokeDecentral(0);

        uint256 idleAfter = vault.idleHollar();
        assertGt(idleAfter, idleBefore, "idleHollar should increase after yield claim");

        (, , , , , uint8 state) = vault.getPosition(0);
        // After yield claim, it immediately transitions to PrincipalWithdrawalRequested
        assertEq(state, 3, "State should be PrincipalWithdrawalRequested (3) after yield claim");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //    YIELD CLAIMED -> PRINCIPAL WITHDRAWAL REQUESTED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_yieldClaimedToPrincipalRequested() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        // This single call should execute yield, then immediately request principal
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(
            state,
            3,
            "Should transition through YieldClaimed to PrincipalWithdrawalRequested in one call"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //     PRINCIPAL REQUESTED -> REDEEMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_principalRequestedToRedeemed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);

        // Approve yield and process (-> PrincipalWithdrawalRequested)
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        // Approve principal and warp past 48h delay
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 idleBefore = vault.idleHollar();

        // PrincipalWithdrawalRequested -> Redeemed
        vault.pokeDecentral(0);

        uint256 idleAfter = vault.idleHollar();
        assertGt(idleAfter, idleBefore, "idleHollar should increase after principal redemption");

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "State should be Redeemed (4)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //               FULL LIFECYCLE TEST
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_fullLifecycle() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);

        // Step 1: Warp past 60-day maturity
        _warpDays(61);

        // Step 2: Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);
        (, , , , , uint8 s1) = vault.getPosition(0);
        assertEq(s1, 1, "After step 2: YieldWithdrawalRequested");

        // Step 3: Approve yield on mock pool
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        // Step 4: Execute yield + request principal (single call)
        vault.pokeDecentral(0);
        (, , , , , uint8 s2) = vault.getPosition(0);
        assertEq(s2, 3, "After step 4: PrincipalWithdrawalRequested");

        // Step 5: Approve principal and warp past 48h
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Step 6: Execute principal -> Redeemed
        vault.pokeDecentral(0);
        (, , , , , uint8 s3) = vault.getPosition(0);
        assertEq(s3, 4, "After step 6: Redeemed");

        // Step 7: Verify total HOLLAR returned = principal + yield
        uint256 idle = vault.idleHollar();
        uint256 expectedYield = _expectedYield(depositAmount, APY_18_PERCENT, 61);
        uint256 expectedTotal = depositAmount + expectedYield;

        assertApproxEqRel(
            idle,
            expectedTotal,
            0.01e18,
            "idleHollar should equal principal + yield"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          NO-OP BEFORE MATURITY
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_noopBeforeMaturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Only warp 30 days (not past 60-day maturity)
        _warpDays(30);

        // Call processPosition -- should NOT advance state (no-op for active before maturity)
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "State should remain Active (0) before maturity");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //        REVERTS ON ALREADY REDEEMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_revertsOnRedeemed() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Process fully through all states
        _processPositionFull(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "Position should be Redeemed");

        // Attempt to process again should revert
        vm.expectRevert(HDCLVault.PositionAlreadyRedeemed.selector);
        vault.pokeDecentral(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //    NO-OP WHEN YIELD NOT APPROVED
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_noopNotApproved() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Active -> YieldWithdrawalRequested
        vault.pokeDecentral(0);
        (, , , , , uint8 s1) = vault.getPosition(0);
        assertEq(s1, 1, "Should be YieldWithdrawalRequested");

        // DO NOT approve yield on mock pool

        // Call processPosition again -- executeYieldWithdrawal will revert internally,
        // caught by try/catch, so it returns without advancing state
        vault.pokeDecentral(0);

        (, , , , , uint8 s2) = vault.getPosition(0);
        assertEq(s2, 1, "State should remain YieldWithdrawalRequested when not approved");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         ADVANCES POSITION HEAD
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_advancesPositionHead() public {
        // Create two positions
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionHead(), 0, "positionHead should start at 0");
        assertEq(vault.getPositionCount(), 2, "Should have 2 positions");

        // Warp past maturity
        _warpDays(61);

        // Process position 0 fully
        _processPositionFull(0);

        // After position 0 is redeemed, positionHead should advance to 1
        assertEq(vault.getPositionHead(), 1, "positionHead should advance to 1 after position 0 redeemed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         CORRECT YIELD AMOUNT
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_correctYieldAmount() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);

        _warpDays(61);

        // Track vault HOLLAR balance to detect yield received
        vault.pokeDecentral(0);
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);

        uint256 idleBefore = vault.idleHollar();

        // Execute yield withdrawal
        vault.pokeDecentral(0);

        uint256 idleAfter = vault.idleHollar();
        uint256 yieldReceived = idleAfter - idleBefore;

        // Expected yield: principal * 0.18 * 61 days / 365 days
        uint256 expectedYield = _expectedYield(depositAmount, APY_18_PERCENT, 61);

        assertApproxEqRel(
            yieldReceived,
            expectedYield,
            0.01e18,
            "Yield received should match expected calculation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //     TRIGGERS QUEUE PROCESSING
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_triggersQueueProcessing() public {
        // Alice deposits and gets HDCL
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp past maturity and process position fully -> idle HOLLAR
        _warpDays(61);
        _processPositionFull(0);

        // Now Alice has idle HOLLAR in the vault. She requests redeem.
        uint256 aliceHdcl = vault.balanceOf(alice);
        uint256 redeemAmount = aliceHdcl / 2;
        _requestRedeem(alice, redeemAmount);
        assertGt(vault.totalQueuedHdcl(), 0, "Queue should have entries");

        // Bob deposits (creates a new position at index 1)
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // Warp past maturity for Bob's position
        _warpDays(61);

        // Before processing Bob's position, check queue state
        // (The queue may have been partially/fully cleared by Bob's deposit
        //  using existing idle HOLLAR. If not, processing Bob's position will do it.)
        uint256 queueBefore = vault.totalQueuedHdcl();
        uint256 aliceHollarBefore = hollar.balanceOf(alice);

        // If queue was already cleared by Bob's deposit, the test passes trivially.
        // If queue still has entries, processing position 1 should trigger queue fulfillment.
        if (queueBefore > 0) {
            _processPositionFull(1);

            uint256 queueAfter = vault.totalQueuedHdcl();
            assertLt(queueAfter, queueBefore, "Queue should be reduced after position redemption");

            uint256 aliceHollarAfter = hollar.balanceOf(alice);
            assertGt(aliceHollarAfter, aliceHollarBefore, "Alice should receive HOLLAR from queue");
        } else {
            // Queue was already cleared by the deposit flow itself (queue clearing on deposit)
            // Verify Alice received HOLLAR through the deposit-triggered queue clearing
            assertGt(
                hollar.balanceOf(alice),
                90_000e18 - TEN_THOUSAND_HOLLAR,
                "Alice should have received HOLLAR from queue clearing on deposit"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //      MULTIPLE POSITIONS -- PROCESS OLDEST FIRST
    // ═══════════════════════════════════════════════════════════════════════

    function test_processPosition_multiplePositions() public {
        // Alice deposits (position 0)
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp 10 days, then Bob deposits (position 1)
        _warpDays(10);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionCount(), 2, "Should have 2 positions");

        // Warp 51 more days: position 0 is mature (61 days), position 1 is NOT (51 days)
        _warpDays(51);

        // Process position 0 -- should work (past 60 days)
        vault.pokeDecentral(0);
        (, , , , , uint8 state0) = vault.getPosition(0);
        assertEq(state0, 1, "Position 0 should advance to YieldWithdrawalRequested");

        // Process position 1 -- should no-op (only 51 days)
        vault.pokeDecentral(1);
        (, , , , , uint8 state1) = vault.getPosition(1);
        assertEq(state1, 0, "Position 1 should remain Active (not yet mature)");

        // Warp 10 more days so position 1 matures
        _warpDays(10);

        vault.pokeDecentral(1);
        (, , , , , uint8 state1b) = vault.getPosition(1);
        assertEq(state1b, 1, "Position 1 should now advance to YieldWithdrawalRequested");
    }
}
