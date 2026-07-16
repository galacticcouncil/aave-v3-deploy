// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

/// @title Multi-Pool Heterogeneous APY — End-to-End Correctness
/// @notice Spins up a second Decentral pool at a higher APY, layers
///         overlapping deposits across both pools, and verifies that
///         deposits, accrual, redemption rate, and claim payouts all stay
///         consistent with per-position rate snapshots.
contract MultiPoolHeterogeneousAPYTest is BaseTest {
    MockDecentralPool internal pool22;
    MockPoolToken internal nft22;
    MockDecentralPool internal pool16;
    MockPoolToken internal nft16;

    uint256 internal constant APY_22 = 0.22e18; // second pool (rate hike)
    uint256 internal constant APY_16 = 0.16e18; // third pool (rate cut)
    // BaseTest defines APY_18_PERCENT = 0.18e18 for the initial pool

    function setUp() public override {
        super.setUp();
        // Second Decentral pool: same HOLLAR, distinct NFT contract, 22% APY.
        nft22 = new MockPoolToken();
        pool22 = new MockDecentralPool(address(hollar), address(nft22), APY_22);
        nft22.registerPool(address(pool22));
        hollar.mint(address(pool22), 10_000_000e18);

        // Third Decentral pool: 16% APY (rate cut from 18%/22%).
        nft16 = new MockPoolToken();
        pool16 = new MockDecentralPool(address(hollar), address(nft16), APY_16);
        nft16.registerPool(address(pool16));
        hollar.mint(address(pool16), 10_000_000e18);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _registerAndActivatePool22() internal {
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool22)));
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool22)));
    }

    function _registerAndActivatePool16() internal {
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool16)));
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool16)));
    }

    /// @dev Simple-interest yield: principal * apy * elapsed / (YEAR * WAD).
    ///      Matches the vault's totalAssets formula and Decentral's payout
    ///      model under the mock.
    function _expectedYield(uint256 principal, uint256 apyWad, uint256 elapsedSeconds)
        internal
        pure
        returns (uint256)
    {
        return (principal * apyWad * elapsedSeconds) / (365 days * 1e18);
    }

    /// @dev Drive a position fully to Redeemed via a specific Decentral pool.
    ///      BaseTest's `_processPositionFull` assumes pool 1; this variant
    ///      lets multi-pool tests target the right pool for each position.
    function _processPositionFullVia(uint256 positionIndex, MockDecentralPool poolImpl) internal {
        vault.pokeDecentral(positionIndex);
        (uint256 tokenId, , , , , ) = vault.getPosition(positionIndex);
        poolImpl.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(positionIndex);
        poolImpl.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        vault.pokeDecentral(positionIndex);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ROUTING: deposits land in the active pool, per-position apy snapshot
    // ═══════════════════════════════════════════════════════════════════════

    function test_routing_positionsAnchoredToTheirPools() public {
        // T=0: alice deposits → position 0 in pool 1 (18%)
        _deposit(alice, 10_000e18);
        assertEq(address(vault.positionPool(0)), address(pool));
        (, , uint256 apy0, , , ) = vault.getPosition(0);
        assertEq(apy0, APY_18_PERCENT, "pos 0 snapshots 18%");

        // T=30d: switch to pool 2 (22%); bob and carol deposit
        _warpDays(30);
        _registerAndActivatePool22();

        _deposit(bob, 10_000e18);
        _deposit(charlie, 5_000e18);

        // Pool anchors + APY snapshots
        assertEq(address(vault.positionPool(1)), address(pool22), "pos 1 in pool 2");
        assertEq(address(vault.positionPool(2)), address(pool22), "pos 2 in pool 2");
        (, , uint256 apy1, , , ) = vault.getPosition(1);
        (, , uint256 apy2, , , ) = vault.getPosition(2);
        assertEq(apy1, APY_22, "pos 1 snapshots 22%");
        assertEq(apy2, APY_22, "pos 2 snapshots 22%");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ACCRUAL: totalAssets() sums heterogeneous APYs correctly
    // ═══════════════════════════════════════════════════════════════════════

    function test_accrual_mixedAPYsAggregateCorrectly() public {
        // T=0: alice into 18%
        _deposit(alice, 10_000e18);

        // T=30d: bob + carol into 22%
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);
        _deposit(charlie, 5_000e18);

        // T=60d: check totalAssets against the per-position simple-interest sum
        _warpDays(30);

        // Pos 0 (18%) has been live 60 days; pos 1+2 (22%) have been live 30 days.
        uint256 y0 = _expectedYield(10_000e18, APY_18_PERCENT, 60 days);
        uint256 y1 = _expectedYield(10_000e18, APY_22, 30 days);
        uint256 y2 = _expectedYield(5_000e18,  APY_22, 30 days);
        uint256 expectedYield = y0 + y1 + y2;

        // 25k total principal across the three positions
        uint256 expectedTotalAssets = 25_000e18 + expectedYield;

        assertApproxEqRel(
            vault.totalAssets(),
            expectedTotalAssets,
            0.001e18,
            "totalAssets matches per-position simple-interest sum"
        );
    }

    function test_accrual_exchangeRateAppreciatesProportionally() public {
        // T=0: alice deposits at 18% (rate ≈ 1.0)
        uint256 aliceBil = _deposit(alice, 10_000e18);
        assertApproxEqRel(vault.exchangeRate(), 1e18, 0.001e18, "rate ~1.0 at first deposit");

        // T=30d: rate has appreciated from 30d × 18% accrual on alice's 10k
        _warpDays(30);
        uint256 rateAt30d = vault.exchangeRate();
        assertGt(rateAt30d, 1e18, "rate appreciates from 18% accrual");

        // Activate pool 22 and have bob deposit at the appreciated rate
        _registerAndActivatePool22();
        uint256 bobBil = _deposit(bob, 10_000e18);

        // Bob's hDCL count reflects buying in at appreciated rate (he gets fewer
        // shares than alice did per HOLLAR).
        assertLt(bobBil, aliceBil, "bob bought in at appreciated rate, fewer hDCL per HOLLAR");

        // T=60d: rate appreciates further — weighted blend of 18% + 22%
        _warpDays(30);
        uint256 rateAt60d = vault.exchangeRate();
        assertGt(rateAt60d, rateAt30d, "rate keeps growing under mixed accrual");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   LIFECYCLE: each pool processes its own positions independently
    // ═══════════════════════════════════════════════════════════════════════

    function test_lifecycle_eachPoolHandlesOwnPositions() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // Move past maturity for pos 0 (60d from t=0) but not yet pos 1 (60d from t=30d).
        _warpDays(35); // t = 65d
        // Pos 0 should be processable; pos 1 not mature yet (matures at t=90d).

        // Process pos 0 fully (via pool 1)
        _processPositionFull(0);
        (, , , , , uint8 state0) = vault.getPosition(0);
        assertEq(state0, 4, "pos 0 redeemed via pool 1");

        // Pos 1 should still be Active
        (, , , , , uint8 state1) = vault.getPosition(1);
        assertEq(state1, 0, "pos 1 still active, not yet matured");

        // Warp past pos 1's maturity (at t=30d + 60d = t=90d)
        _warpDays(30); // t = 95d
        _processPositionFullVia(1, pool22);
        (, , , , , uint8 state1b) = vault.getPosition(1);
        assertEq(state1b, 4, "pos 1 redeemed via pool 2");
    }

    function test_lifecycle_yieldPaidAtPositionsOwnRate() public {
        // Alice in pool 1 (18%)
        _deposit(alice, 10_000e18);
        _warpDays(30);

        // Bob in pool 2 (22%)
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // Mature pos 0 (alice's, 18%)
        _warpDays(35); // t=65d

        uint256 idleBefore = vault.idleHollar();
        _processPositionFull(0);
        uint256 idleAfter = vault.idleHollar();

        // Position 0 should have yielded principal + ~18% × 65 days of yield
        uint256 expectedAliceYield = _expectedYield(10_000e18, APY_18_PERCENT, 65 days);
        uint256 expectedFromAlice = 10_000e18 + expectedAliceYield;

        assertApproxEqRel(
            idleAfter - idleBefore,
            expectedFromAlice,
            0.01e18,
            "alice's pool-1 position pays 18% yield"
        );

        // Mature pos 1 (bob's, 22%) — total elapsed for bob = 65d (he joined at t=30d, now at t=95d)
        _warpDays(30); // t=95d

        idleBefore = vault.idleHollar();
        _processPositionFullVia(1, pool22);
        idleAfter = vault.idleHollar();

        uint256 expectedBobYield = _expectedYield(10_000e18, APY_22, 65 days);
        uint256 expectedFromBob = 10_000e18 + expectedBobYield;

        assertApproxEqRel(
            idleAfter - idleBefore,
            expectedFromBob,
            0.01e18,
            "bob's pool-2 position pays 22% yield"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   REDEMPTION: rate-lock + claim across mixed-pool history
    // ═══════════════════════════════════════════════════════════════════════

    function test_redemption_paidAtBlendedRate() public {
        // Setup: alice 10k in 18%, bob 10k in 22% (deposited at t=30d)
        _deposit(alice, 10_000e18);
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // T=65d: alice's position matures, gets processed. Idle now has
        // alice's principal + yield, ready to fulfill redemptions.
        _warpDays(35);
        _processPositionFull(0);

        // Bob requests redemption of all his hDCL
        uint256 bobBil = vault.balanceOf(bob);
        uint256 bobReq = _requestRedeem(bob, bobBil);

        // Capture the rate at which the queue will settle
        uint256 rateAtSettle = vault.exchangeRate();

        // Settle the queue
        vault.pokeQueue();

        // Bob's settled HOLLAR should match the rate-lock at settlement time
        (, , uint256 settled, uint256 owed, ) = vault.getRedemptionRequest(bobReq);
        uint256 expectedOwed = (settled * rateAtSettle) / 1e18;
        assertApproxEqRel(owed, expectedOwed, 0.001e18, "rate-lock matches exchangeRate at settle");

        // Claim and verify the actual HOLLAR matches the rate-locked amount
        uint256 bobBefore = hollar.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(settled, bob, bob);
        uint256 bobAfter = hollar.balanceOf(bob);

        assertEq(bobAfter - bobBefore, owed, "claim pays exactly the locked amount");

        // The amount bob received reflects yield from BOTH alice's 18% (which
        // appreciated the rate before bob deposited) AND bob's own 22% accrual.
        // Should beat his original 10k deposit.
        assertGt(bobAfter - bobBefore, 10_000e18, "bob earned more than his deposit");
    }

    function test_redemption_fifoAcrossPools() public {
        _deposit(alice, 10_000e18);
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // Mature alice's position to seed idle for redemptions
        _warpDays(35);
        _processPositionFull(0);

        // Bob and alice both queue redemptions (alice has hDCL too)
        uint256 bobBil = vault.balanceOf(bob);
        uint256 aliceBil = vault.balanceOf(alice);

        _requestRedeem(alice, aliceBil / 2); // req 0
        _requestRedeem(bob, bobBil / 2);     // req 1

        uint256 idleSnapshot = vault.idleHollar();

        vault.pokeQueue();

        // FIFO: alice (req 0) settles first. If idle covers her in full, her
        // claimable should equal her requested amount. If not, partial.
        (, , uint256 aliceSettled, , ) = vault.getRedemptionRequest(0);
        if (aliceSettled == aliceBil / 2) {
            // alice fully settled — bob may be partial or fully settled too
            assertGt(idleSnapshot, 0, "had idle to settle alice fully");
        } else {
            // alice partially settled — bob should be 0
            (, , uint256 bobSettled, , ) = vault.getRedemptionRequest(1);
            assertEq(bobSettled, 0, "bob untouched until alice fully settled");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FULL CYCLE: deposit → wait → redeem → claim across both pools
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullCycle_bothPoolsAndClaim() public {
        // T=0: alice in pool 1 (18%)
        uint256 aliceHollarStart = hollar.balanceOf(alice);
        _deposit(alice, 10_000e18);

        // T=30d: bob in pool 2 (22%) at appreciated rate
        _warpDays(30);
        _registerAndActivatePool22();
        uint256 bobHollarStart = hollar.balanceOf(bob);
        _deposit(bob, 10_000e18);

        // T=65d: alice's pool-1 position matures and gets processed
        _warpDays(35);
        _processPositionFull(0);

        // Alice queues her full hDCL balance
        uint256 aliceBil = vault.balanceOf(alice);
        _requestRedeem(alice, aliceBil);
        vault.pokeQueue();
        _claimAll(alice);

        // Alice received principal + her 18% × 65d yield (approximately)
        uint256 aliceHollarRecovered = hollar.balanceOf(alice) - (aliceHollarStart - 10_000e18);
        uint256 expectedAliceYield = _expectedYield(10_000e18, APY_18_PERCENT, 65 days);
        assertApproxEqRel(
            aliceHollarRecovered,
            10_000e18 + expectedAliceYield,
            0.01e18,
            "alice recovered principal + 18pct x 65d yield"
        );

        // T=95d: bob's pool-2 position matures and gets processed.
        // This internal-pokeQueue call may also rate-lock any leftover pending
        // alice had (the residual from her partial fulfillment at t=65d), so
        // we need to claim her again at the end.
        _warpDays(30);
        _processPositionFullVia(1, pool22);

        // Bob queues his full hDCL
        uint256 bobBil = vault.balanceOf(bob);
        _requestRedeem(bob, bobBil);
        vault.pokeQueue();
        _claimAll(bob);
        // Alice claims any leftover that settled in the second pokeQueue
        _claimAll(alice);

        // Bob received more than his 10k deposit:
        //   - he bought in at appreciated rate (some of alice's 18% × 30d)
        //   - then earned 22% × 65d on his pool-2 position
        uint256 bobHollarRecovered = hollar.balanceOf(bob) - (bobHollarStart - 10_000e18);
        assertGt(bobHollarRecovered, 10_000e18, "bob exits with positive yield");

        // Sanity: the system is solvent after all redemptions.
        // Remaining hDCL is just the DEAD_SHARES; remaining HOLLAR (if any)
        // is the rounding residue from the pull-redemption math.
        assertEq(vault.totalQueuedBil(), 0, "queue cleared");
        assertEq(vault.totalReservedHollar(), 0, "no reserved HOLLAR left");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   THREE POOLS: 18% → 22% → 16% (rate hike then rate cut)
    // ═══════════════════════════════════════════════════════════════════════

    function test_threePools_aggregateAccrual() public {
        // T=0: alice into 18% (pool 1)
        _deposit(alice, 10_000e18);

        // T=30d: switch active to pool 2 (22%); bob deposits
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // T=60d: switch active to pool 3 (16%); charlie deposits
        _warpDays(30);
        vault.syncMaturities(1); // checkpoint alice at her 60d maturity
        _registerAndActivatePool16();
        _deposit(charlie, 10_000e18);

        // Routing sanity: each position anchored to the right pool with the
        // right snapshotted APY.
        assertEq(address(vault.positionPool(0)), address(pool));
        assertEq(address(vault.positionPool(1)), address(pool22));
        assertEq(address(vault.positionPool(2)), address(pool16));
        (, , uint256 apy0, , , ) = vault.getPosition(0);
        (, , uint256 apy1, , , ) = vault.getPosition(1);
        (, , uint256 apy2, , , ) = vault.getPosition(2);
        assertEq(apy0, APY_18_PERCENT);
        assertEq(apy1, APY_22);
        assertEq(apy2, APY_16);

        // T=90d: all three have accrued for different durations
        _warpDays(30);

        uint256 y0 = _expectedYield(10_000e18, APY_18_PERCENT, 60 days);
        uint256 y1 = _expectedYield(10_000e18, APY_22,         60 days);
        uint256 y2 = _expectedYield(10_000e18, APY_16,         30 days);
        uint256 expectedTotalAssets = 30_000e18 + y0 + y1 + y2;

        assertApproxEqRel(
            vault.totalAssets(),
            expectedTotalAssets,
            0.001e18,
            "three-pool accrual sums correctly across heterogeneous APYs"
        );
    }

    /// @notice A rate cut on the active pool MUST NOT slow yield on positions
    ///         already minted under higher-APY pools. Each position locks its
    ///         APY at deposit time; later pool switches don't affect it.
    function test_rateCut_doesNotAffectExistingPositions() public {
        // T=0: alice into 18%
        _deposit(alice, 10_000e18);

        // T=30d: switch to 22%; bob deposits
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // Snapshot bob's pre-cut accrual: 0 yield yet
        // T=45d: 15 days of 22% on bob's position so far
        _warpDays(15);
        uint256 bobAccrual15d = _expectedYield(10_000e18, APY_22, 15 days);
        // Also some alice accrual (45 days at 18%)
        uint256 aliceAccrual45d = _expectedYield(10_000e18, APY_18_PERCENT, 45 days);
        uint256 expectedAt45d = 20_000e18 + aliceAccrual45d + bobAccrual15d;
        assertApproxEqRel(vault.totalAssets(), expectedAt45d, 0.001e18, "pre-cut accrual ok");

        // Rate cut: switch active to 16%
        _registerAndActivatePool16();

        // No deposit yet, but the cut shouldn't have changed anything in
        // totalAssets — existing positions still accrue at their snapshotted
        // rates (18% for alice, 22% for bob).
        assertApproxEqRel(vault.totalAssets(), expectedAt45d, 0.001e18, "cut alone changes nothing");

        // T=75d: another 30 days. Alice is capped at her T=60 maturity while
        // Bob's snapshotted 22% position continues accruing. The active pool
        // is 16% but it still has zero positions.
        _warpDays(30);
        vault.syncMaturities(1); // alice capped at T=60d; bob remains live

        uint256 aliceAccrual60d = _expectedYield(10_000e18, APY_18_PERCENT, 60 days);
        uint256 bobAccrual45d   = _expectedYield(10_000e18, APY_22,         45 days);
        uint256 expectedAt75d = 20_000e18 + aliceAccrual60d + bobAccrual45d;
        assertApproxEqRel(
            vault.totalAssets(),
            expectedAt75d,
            0.001e18,
            "existing positions keep their original APYs after cut"
        );

        // Now charlie deposits under the 16% regime
        _deposit(charlie, 10_000e18);
        (, , uint256 apy2, , , ) = vault.getPosition(2);
        assertEq(apy2, APY_16, "new deposit gets the cut rate");

        // The blended rate continues to grow — slower than before — but
        // existing positions are unaffected.
        _warpDays(15); // T=90d
        uint256 bobAccrual60d    = _expectedYield(10_000e18, APY_22,         60 days);
        uint256 charlieAccrual15d = _expectedYield(10_000e18, APY_16,        15 days);
        uint256 expectedAt90d = 30_000e18 + aliceAccrual60d + bobAccrual60d + charlieAccrual15d;
        assertApproxEqRel(vault.totalAssets(), expectedAt90d, 0.001e18, "post-cut blend");
    }

    /// @notice Full lifecycle across three different APYs, claiming each user
    ///         and verifying everyone exits with the yield their snapshot APY
    ///         should have produced — including the user that joined under
    ///         the rate-cut regime.
    function test_threePools_fullCycle() public {
        uint256 aliceStart   = hollar.balanceOf(alice);
        uint256 bobStart     = hollar.balanceOf(bob);
        uint256 charlieStart = hollar.balanceOf(charlie);

        // T=0: alice @ 18%
        _deposit(alice, 10_000e18);

        // T=30d: switch to 22%; bob deposits
        _warpDays(30);
        _registerAndActivatePool22();
        _deposit(bob, 10_000e18);

        // T=60d: switch to 16%; charlie deposits
        _warpDays(30);
        vault.syncMaturities(1); // checkpoint alice before the new deposit
        _registerAndActivatePool16();
        _deposit(charlie, 10_000e18);

        // T=65d: alice's pool-1 position matures (60d from t=0); process it
        _warpDays(5);
        _processPositionFull(0);

        // Alice queues and claims her full position
        _requestRedeem(alice, vault.balanceOf(alice));
        vault.pokeQueue();
        _claimAll(alice);

        // Alice should recover principal + 65 days of 18% accrual
        uint256 aliceRecovered = hollar.balanceOf(alice) - (aliceStart - 10_000e18);
        uint256 aliceExpected = 10_000e18 + _expectedYield(10_000e18, APY_18_PERCENT, 65 days);
        assertApproxEqRel(aliceRecovered, aliceExpected, 0.01e18, "alice exits with 18% yield");

        // T=95d: bob's pool-2 position matures (60d from t=30d); process via pool22
        _warpDays(30);
        _processPositionFullVia(1, pool22);

        _requestRedeem(bob, vault.balanceOf(bob));
        vault.pokeQueue();
        _claimAll(bob);
        // Also claim any residual alice had from partial settlement during
        // bob's auto-pokeQueue, so the final accounting is clean.
        _claimAll(alice);

        // Bob's recovery should reflect his entry-rate appreciation (alice's
        // 30 days of 18% on her 10k before bob joined) plus his own 65 days
        // of 22% accrual on his position.
        uint256 bobRecovered = hollar.balanceOf(bob) - (bobStart - 10_000e18);
        assertGt(bobRecovered, 10_000e18, "bob exits with positive yield");

        // T=125d: charlie's pool-3 position matures (60d from t=60d); process via pool16
        _warpDays(30);
        _processPositionFullVia(2, pool16);

        _requestRedeem(charlie, vault.balanceOf(charlie));
        vault.pokeQueue();
        _claimAll(charlie);

        // Charlie joined when the rate was already appreciated, then earned
        // 16% for 65 days. He should exit with positive yield even at the
        // cut rate — the appreciation from previous positions carried him.
        uint256 charlieRecovered = hollar.balanceOf(charlie) - (charlieStart - 10_000e18);
        assertGt(charlieRecovered, 10_000e18, "charlie exits with positive yield despite rate cut");

        // System solvent after all three exit
        assertEq(vault.totalQueuedBil(), 0, "queue cleared");
        assertEq(vault.totalReservedHollar(), 0, "no reserved HOLLAR left");
    }
}
