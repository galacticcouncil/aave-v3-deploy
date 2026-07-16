// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILOracle} from "../../src/BILOracle.sol";

/// @notice Audit finding H-01: pre-fix, `totalAssets()` continued accruing
///         virtual yield past `maturityTime` until a keeper pokes the position,
///         because `block.timestamp * yieldRateSum` was not capped at maturity.
///         `pokeDecentral`'s `pendingYield` calc used the same uncapped
///         formula, which locked the inflated value into `totalPendingYield`
///         until `executeYieldWithdrawal` revealed the actual (lower) Decentral
///         payout and the shortfall was socialised through `exchangeRate()`.
///
///         The fix indexes active positions in a maturity min-heap. View
///         accounting clamps the aggregate at the earliest unprocessed
///         maturity, so the oracle is safe without a keeper transaction.
///         Queue settlement synchronizes a bounded set of due roots, while
///         deposits refuse to proceed until the backlog is explicitly drained.
///
///         These tests assert the post-fix behaviour: (a) the rate and oracle
///         are stable past maturity without cleanup, (b) pendingYield equals
///         the maturity-capped projection, and (c) requestRedeem + pokeQueue
///         cannot atomically lock an inflated rate.
contract PostMaturityYieldDriftTest is BaseTest {
    /// @notice View accounting and the oracle cap without any cleaner tx.
    function test_H01_viewAndOracleCapWithoutAnySync() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        BILOracle priceFeed = new BILOracle(address(vault));

        _warpDays(59);
        uint256 rateBeforeMaturity = vault.exchangeRate();
        _warpDays(1);
        uint256 assetsAtMaturity = vault.totalAssets();
        uint256 rateAtMaturity = vault.exchangeRate();
        (, int256 answerAtMaturity, , , ) = priceFeed.latestRoundData();
        assertGt(rateAtMaturity, rateBeforeMaturity, "yield reaches maturity");

        // No cleaner, keeper, poke, or other state change occurs.
        _warpDays(14);
        assertEq(vault.totalAssets(), assetsAtMaturity, "assets capped without sync");
        assertEq(vault.exchangeRate(), rateAtMaturity, "rate capped without sync");
        (, int256 answerAfterDelay, , , ) = priceFeed.latestRoundData();
        assertEq(answerAfterDelay, answerAtMaturity, "oracle capped without sync");
        assertEq(vault.totalPendingYield(), 0, "no hidden state cleanup occurred");
    }

    /// @notice Maturity synchronization is idempotent.
    function test_H01_syncMaturities_idempotent() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        _warpDays(60);
        assertEq(vault.syncMaturities(1), 1);
        uint256 rateAfterFirstClean = vault.exchangeRate();
        uint256 pendingAfterFirstClean = vault.totalPendingYield();

        // Second call same block — no-op.
        assertEq(vault.syncMaturities(1), 0);
        assertEq(vault.exchangeRate(), rateAfterFirstClean, "rate unchanged after redundant clean");
        assertEq(vault.totalPendingYield(), pendingAfterFirstClean, "pending unchanged after redundant clean");

        // Warp + clean again — still a no-op because pendingYield != 0.
        _warpDays(7);
        assertEq(vault.syncMaturities(1), 0);
        assertEq(vault.exchangeRate(), rateAfterFirstClean, "rate flat across redundant late clean");
        assertEq(vault.totalPendingYield(), pendingAfterFirstClean, "pending flat across redundant late clean");
    }

    /// @notice Synchronization is a no-op before the earliest maturity.
    function test_H01_syncMaturities_pre_maturity_is_noop() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 rateBefore = vault.exchangeRate();
        uint256 pendingBefore = vault.totalPendingYield();

        // Still well before maturity. Clean is a no-op.
        _warpDays(30);
        assertEq(vault.syncMaturities(1), 0);

        // The rate should reflect 30 days of legitimate accrual — unchanged
        // by the sync call. pendingYield should also be unchanged (0).
        assertGt(vault.exchangeRate(), rateBefore, "30d legitimate accrual visible");
        assertEq(vault.totalPendingYield(), pendingBefore, "no pending yield locked pre-maturity");

        // The position is still Active and uncapped (pendingYield == 0).
        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "still Active");
    }

    /// @notice After the fix, the `pendingYield` recorded at the
    ///         Active→YieldWithdrawalRequested transition reflects the
    ///         maturity-capped (60-day) value, not the inflated 74-day
    ///         projection. The Decentral execute payout matches expectation
    ///         exactly — no shortfall socialises through the rate.
    function test_H01_pendingYield_capped_at_maturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 14 days past maturity, no poke.
        _warpDays(60 + 14);

        // The mock accrues until the late request at day 74, so below we apply
        // a negative payout adjustment to model Decentral's 60-day cap. We
        // compute both reference values to make the assertion explicit.
        uint256 principal = TEN_THOUSAND_HOLLAR;
        uint256 yieldFor60d = (principal * APY_18_PERCENT * 60 days) /
            (365 days * 1e18);
        uint256 yieldFor74d = (principal * APY_18_PERCENT * 74 days) /
            (365 days * 1e18);

        // Active → YieldWithdrawalRequested. With the fix, pendingYield is the
        // 60-day capped projection regardless of how late the poke is.
        vault.pokeDecentral(0);
        (, , , , , uint8 stateAfter) = vault.getPosition(0);
        assertEq(stateAfter, 1, "state is YieldWithdrawalRequested"); // enum index 1

        uint256 totalPendingAfterRequest = vault.totalPendingYield();
        assertApproxEqRel(
            totalPendingAfterRequest,
            yieldFor60d,
            0.01e18,
            "totalPendingYield equals the 60-day capped projection, not 74-day"
        );
        // Strict upper bound: must be strictly less than the inflated value.
        assertLt(
            totalPendingAfterRequest,
            yieldFor74d,
            "totalPendingYield must NOT match the pre-fix 74-day inflation"
        );

        // Decentral approves and the vault executes. Configure the mock to pay
        // exactly the 60-day amount (no overpay, no shortfall) — this is what
        // a maturity-respecting Decentral would do.
        int256 yieldAdjustment = int256(yieldFor60d) -
            int256((principal * APY_18_PERCENT * 74 days) / (365 days * 1e18));
        pool.setYieldDelta(_tokenIdOf(0), yieldAdjustment);

        uint256 taBeforeExecute = vault.totalAssets();
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);

        uint256 taAfterExecute = vault.totalAssets();
        // With the fix the locked pendingYield (60d) matches the Decentral
        // payout (60d), so totalAssets is invariant across execute. Allow
        // 1-wei tolerance for division rounding in the mock.
        assertApproxEqAbs(
            taAfterExecute,
            taBeforeExecute,
            1,
            "totalAssets invariant across execute - no shortfall to socialise"
        );
    }

    /// @notice Attack: a matured-but-unprocessed position is left untouched,
    ///         then requestRedeem + pokeQueue are called back-to-back. Queue
    ///         settlement must synchronize before it rate-locks the request.
    ///
    ///         Setup uses three positions:
    ///         - Position 0 (Alice): fully redeemed early, leaving idle HOLLAR
    ///         - Position 1 (Bob, the attacker): matured but unpoked
    ///         - Position 2 (Charlie): a long-term holder
    function test_H01_atomicRateLockAttackFailsWithoutCleaner() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Alice matures first; Bob and Charlie start two weeks later.
        _warpDays(14);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        // At T+60d Alice returns idle liquidity while the other positions are
        // still live. _processPositionFull advances another 48h to T+62d.
        _warpDays(46);
        _processPositionFull(0);
        uint256 idle = vault.idleHollar();
        assertGt(idle, TEN_THOUSAND_HOLLAR, "idleHollar from Alice's full redeem");

        // Snapshot Bob's honest rate at T+74d, then leave his matured position
        // completely untouched for another two weeks.
        _warpDays(12);
        uint256 honestRate = vault.exchangeRate();
        _warpDays(14);
        assertEq(vault.exchangeRate(), honestRate, "stale oracle remains capped");

        // Bob atomically requests and settles without giving a cleaner a turn.
        uint256 bobShares = vault.balanceOf(bob);
        uint256 reqId = _requestRedeem(bob, bobShares);
        vault.pokeQueue();

        (, uint256 bilAmount, uint256 bilSettled, uint256 hollarOwed, ) = vault
            .getRedemptionRequest(reqId);
        assertEq(bilAmount, bobShares, "request bilAmount = full shares");
        assertGt(bilSettled, 0, "at least partial settle from idleHollar");

        uint256 hollarOwedPerBil = (hollarOwed * 1e18) / bilSettled;
        assertLe(hollarOwedPerBil, honestRate, "cannot lock phantom yield");
        assertApproxEqAbs(hollarOwedPerBil, honestRate, 2, "locks honest rate");
    }

    function _tokenIdOf(uint256 positionIndex) internal view returns (uint256) {
        (uint256 tokenId, , , , , ) = vault.getPosition(positionIndex);
        return tokenId;
    }
}
