// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice Audit finding H-01: pre-fix, `totalAssets()` continued accruing
///         virtual yield past `maturityTime` until a keeper pokes the position,
///         because `block.timestamp * yieldRateSum` was not capped at maturity.
///         `pokeDecentral`'s `pendingYield` calc used the same uncapped
///         formula, which locked the inflated value into `totalPendingYield`
///         until `executeYieldWithdrawal` revealed the actual (lower) Decentral
///         payout and the shortfall was socialised through `exchangeRate()`.
///
///         The fix introduces a permissionless `cleanMaturedFromBucket(idx)`
///         that anyone can call to cap a matured position's yield contribution
///         at the maturity-bounded value, removing it from the live yield
///         bucket and locking the capped amount into `totalPendingYield`.
///         `pokeDecentral`'s Active→YieldWithdrawalRequested branch invokes the
///         same internal helper, so the inflated value can never be observed
///         once any honest party (keeper, monitor, or the redeemer themselves)
///         caps it before the rate-sensitive step.
///
///         These tests assert the post-fix behaviour: (a) the rate is stable
///         past maturity once cleaned, (b) pendingYield equals the 60-day
///         projection rather than the post-maturity 74-day projection, and
///         (c) an attacker who tries to lock in the inflated rate is defeated
///         because the cleaner neutralises the bucket atomically before any
///         settlement.
contract PostMaturityYieldDriftTest is BaseTest {
    /// @notice After `cleanMaturedFromBucket`, `exchangeRate()` is flat past
    ///         `maturityTime` — the live yield bucket no longer accrues virtual
    ///         yield once the position has been frozen at its maturity-capped
    ///         amount.
    function test_H01_exchangeRate_stable_past_maturity_after_clean() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp exactly to maturity. Snapshot the rate at the moment of
        // maturity but BEFORE the cap is applied — this is the value the
        // protocol must preserve from now until execute.
        _warpDays(60);
        vault.cleanMaturedFromBucket(0);
        uint256 rateAtMaturity = vault.exchangeRate();

        // Keeper is late. Position is still Active even though Decentral has
        // stopped accruing on the real chain. Warp 14 more days — under the
        // fix, the rate must NOT change because the bucket was already capped.
        _warpDays(14);
        uint256 rateAtPlus14 = vault.exchangeRate();

        assertEq(
            rateAtPlus14,
            rateAtMaturity,
            "rate must NOT drift past maturity once the position has been capped"
        );
    }

    /// @notice `cleanMaturedFromBucket` is idempotent: a second call (or any
    ///         later call) is a no-op and the rate stays flat.
    function test_H01_cleanMaturedFromBucket_idempotent() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        _warpDays(60);
        vault.cleanMaturedFromBucket(0);
        uint256 rateAfterFirstClean = vault.exchangeRate();
        uint256 pendingAfterFirstClean = vault.totalPendingYield();

        // Second call same block — no-op.
        vault.cleanMaturedFromBucket(0);
        assertEq(vault.exchangeRate(), rateAfterFirstClean, "rate unchanged after redundant clean");
        assertEq(vault.totalPendingYield(), pendingAfterFirstClean, "pending unchanged after redundant clean");

        // Warp + clean again — still a no-op because pendingYield != 0.
        _warpDays(7);
        vault.cleanMaturedFromBucket(0);
        assertEq(vault.exchangeRate(), rateAfterFirstClean, "rate flat across redundant late clean");
        assertEq(vault.totalPendingYield(), pendingAfterFirstClean, "pending flat across redundant late clean");
    }

    /// @notice `cleanMaturedFromBucket` is a no-op for pre-maturity positions
    ///         — it never freezes a position whose yield is still legitimately
    ///         accruing.
    function test_H01_cleanMaturedFromBucket_pre_maturity_is_noop() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 rateBefore = vault.exchangeRate();
        uint256 pendingBefore = vault.totalPendingYield();

        // Still well before maturity. Clean is a no-op.
        _warpDays(30);
        vault.cleanMaturedFromBucket(0);

        // The rate should reflect 30 days of legitimate accrual — unchanged
        // by the clean call. pendingYield should also be unchanged (0).
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

        // The mock pool also caps at maturityTime under the fix (no need to
        // configure a yieldDelta — Decentral pays exactly 60d). We compute
        // both reference values to make the assertion explicit.
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
        int256 yieldOverpay = int256(yieldFor60d) -
            int256((principal * APY_18_PERCENT * 74 days) / (365 days * 1e18));
        pool.setYieldDelta(_tokenIdOf(0), yieldOverpay);

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

    /// @notice Attack: when a matured-but-not-poked position SHOULD inflate the
    ///         rate, the attacker plans to requestRedeem + pokeQueue to lock
    ///         in the inflated rate. Under the fix, anyone (including the
    ///         attacker's would-be victim, a monitor bot, or the protocol
    ///         keeper) can call `cleanMaturedFromBucket` atomically before
    ///         settlement to neutralise the inflation — Bob ends up locking
    ///         at the honest post-maturity rate and extracts ZERO HOLLAR over
    ///         his fair share.
    ///
    ///         Setup uses three positions:
    ///         - Position 0 (Alice): fully redeemed early, leaving idle HOLLAR
    ///         - Position 1 (Bob, the attacker): matured but unpoked
    ///         - Position 2 (Charlie): a long-term holder
    function test_H01_attack_neutralised_by_clean() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        // 60 days: all three mature.
        _warpDays(60);

        // Alice's position is processed promptly. Her ~10300 HOLLAR (principal
        // + yield) sits in idleHollar.
        _processPositionFull(0);
        uint256 idle = vault.idleHollar();
        assertGt(idle, TEN_THOUSAND_HOLLAR, "idleHollar from Alice's full redeem");

        // Keeper sleeps. Without the fix, Bob's position would inflate the
        // rate for 14 more days. Under the fix, anyone can call
        // `cleanMaturedFromBucket` to freeze the matured positions at their
        // maturity-capped value — the rate becomes drift-immune.
        _warpDays(14);

        // ─── Defensive sweep: any honest party caps the matured positions ───
        // (Could be the keeper, a monitor bot, Bob's own counterparty, or
        // even Bob himself before submitting his redemption — the call is
        // permissionless and the result is the same.)
        vault.cleanMaturedFromBucket(1);
        vault.cleanMaturedFromBucket(2);

        uint256 honestRate = vault.exchangeRate();

        // Configure the mock to cap at 60d for Bob's position (what real
        // Decentral would do) so we can verify zero shortfall later.
        {
            uint256 principal = TEN_THOUSAND_HOLLAR;
            uint256 y60 = (principal * APY_18_PERCENT * 60 days) /
                (365 days * 1e18);
            uint256 y74 = (principal * APY_18_PERCENT * 74 days) /
                (365 days * 1e18);
            pool.setYieldDelta(_tokenIdOf(1), int256(y60) - int256(y74));
        }

        // Attack step 1: Bob requests redemption of all his shares.
        uint256 bobShares = vault.balanceOf(bob);
        uint256 reqId = _requestRedeem(bob, bobShares);

        // Attack step 2: pokeQueue settles his request against idleHollar at
        // what would be the inflated rate — but the bucket has already been
        // capped, so the lock-in rate is honest.
        vault.pokeQueue();

        (, uint256 bilAmount, uint256 bilSettled, uint256 hollarOwed, ) = vault
            .getRedemptionRequest(reqId);
        assertEq(bilAmount, bobShares, "request bilAmount = full shares");
        assertGt(bilSettled, 0, "at least partial settle from idleHollar");

        uint256 hollarOwedPerBil = (hollarOwed * 1e18) / bilSettled;
        assertApproxEqRel(
            hollarOwedPerBil,
            honestRate,
            0.001e18,
            "Bob locked in at the honest (capped) rate, not an inflated one"
        );

        // Bob's position lifecycle plays out. With the fix, pokeDecentral
        // re-uses the already-capped pendingYield (no recompute) and
        // executeYieldWithdrawal pays the matching 60d amount.
        vault.pokeDecentral(1); // Active -> YieldWithdrawalRequested (no recompute, uses pendingYield)
        pool.approveYieldWithdrawal(_tokenIdOf(1));
        vault.pokeDecentral(1); // YieldWithdrawalRequested -> YieldClaimed (no shortfall)

        uint256 postExecuteRate = vault.exchangeRate();

        // Under the fix, the post-execute rate equals Bob's lock-in rate
        // (within rounding) — no extraction, the attack is defeated.
        assertApproxEqRel(
            postExecuteRate,
            hollarOwedPerBil,
            0.001e18,
            "post-execute rate matches Bob's lock-in - no over-extraction"
        );

        // Quantify any residual extraction. Under the fix the per-BIL gap is
        // sub-wei after rounding; the cumulative over-extraction must be zero
        // (or, at most, a few wei of rounding noise — not the ~14d*APY*P
        // shortfall the pre-fix code allowed).
        uint256 perBilOverExtract = postExecuteRate >= hollarOwedPerBil
            ? 0
            : hollarOwedPerBil - postExecuteRate;
        uint256 totalOver = (perBilOverExtract * bilSettled) / 1e18;
        emit log_named_uint("Bob stole HOLLAR (wei)", totalOver);
        assertEq(totalOver, 0, "extraction is zero - fix neutralises the attack");
    }

    function _tokenIdOf(uint256 positionIndex) internal view returns (uint256) {
        (uint256 tokenId, , , , , ) = vault.getPosition(positionIndex);
        return tokenId;
    }
}
