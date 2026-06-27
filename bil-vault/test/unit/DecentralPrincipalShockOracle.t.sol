// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";

/// @notice Audit finding H-02: Decentral principal/yield mismatch silently
///         socialises the shortfall through `exchangeRate()` ATOMICALLY in
///         the same transaction. Because `BILOracle` / `BILOracleAdapter`
///         both read `vault.exchangeRate()` live with no smoothing or
///         per-block max-jump clamp, a single bad Decentral payout flows
///         straight into Aave's oracle and the substrate stableswap pool
///         peg. Borrowers whose Aave health factor was within the shock
///         band become liquidatable in the same block; pool 10055's
///         maxPegUpdate=200bp clamp can be exceeded at the edge.
///
///         These tests prove the atomicity of the rate shock under
///         realistic underpayment scenarios (4% / 10% haircuts) and quantify
///         the resulting `exchangeRate()` drop downstream consumers see.
contract DecentralPrincipalShockOracleTest is BaseTest {
    /// @notice A 4% Decentral principal haircut on a single position
    ///         atomically drops the vault's exchange rate by ~1.3% (because
    ///         the position is one-third of vault TVL). Same-tx propagation
    ///         to any downstream oracle.
    function test_H02_principal_shortfall_drops_rate_atomically() public {
        // Three equal positions = simple math (each is 1/3 of vault).
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        // Mature one position.
        _warpDays(60);

        // Process yield, get position 0 into PrincipalWithdrawalRequested.
        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // Configure Decentral to underpay principal by 4% (a realistic small
        // default / partial recovery scenario).
        int256 haircut = -int256((TEN_THOUSAND_HOLLAR * 4) / 100);
        pool.setPayoutDelta(_tokenIdOf(0), haircut);

        // Warp past the 48h withdrawal delay.
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();

        // Single transaction: executes the principal withdrawal. Decentral
        // pays 9,600 HOLLAR instead of 10,000. The 400 HOLLAR shortfall is
        // socialised across all share-holders via `exchangeRate()` in the
        // SAME tx.
        vault.pokeDecentral(0);

        uint256 rateAfter = vault.exchangeRate();

        assertLt(rateAfter, rateBefore, "rate dropped in same tx as underpay");

        uint256 dropBps = ((rateBefore - rateAfter) * 10_000) / rateBefore;
        emit log_named_uint("exchange rate drop (bps)", dropBps);

        // Position 0 was ~1/3 of TVL; a 4% haircut on that position is
        // ~4/3 % ~= 133 bps of total vault value. The actual drop should
        // exceed 100 bps (1%) -- well above the stableswap 10055
        // maxPegUpdate=200bp clamp would tolerate if shifted in the wrong
        // direction in a short window.
        assertGt(dropBps, 100, "drop > 1% -- exceeds 1bp tolerance for stable oracle");
    }

    /// @notice A larger 10% haircut on the SAME position (1/3 of TVL) drops
    ///         the vault's rate by >3% atomically -- far above the substrate
    ///         stableswap's maxPegUpdate=200bp per-block clamp, meaning the
    ///         pool will mis-price aBIL against HOLLAR until the next block
    ///         and is exposed to immediate arb-drain.
    function test_H02_large_shortfall_exceeds_pool_peg_clamp() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        _warpDays(60);

        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // 10% haircut.
        int256 haircut = -int256(TEN_THOUSAND_HOLLAR / 10);
        pool.setPayoutDelta(_tokenIdOf(0), haircut);

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        uint256 dropBps = ((rateBefore - rateAfter) * 10_000) / rateBefore;
        emit log_named_uint("10% haircut -> rate drop (bps)", dropBps);

        // Position is ~1/3 of TVL; a 10% haircut on it ~= 333 bps of vault
        // value. The substrate stableswap 10055 has maxPegUpdate = 200 bps
        // per block -- this shock exceeds the clamp.
        assertGt(
            dropBps,
            200,
            "shock exceeds stableswap maxPegUpdate=200bp clamp"
        );
    }

    /// @notice Atomicity proof: the rate drop happens in the SAME block as
    ///         the underpayment, with no per-block jump-limit / smoothing in
    ///         between. Downstream oracle consumers (Aave, the stableswap
    ///         peg source) see the new low price atomically.
    function test_H02_rate_change_visible_same_block() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        _warpDays(60);

        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // 8% haircut -- half of vault TVL x 8% = ~4% rate shock.
        pool.setPayoutDelta(
            _tokenIdOf(0),
            -int256((TEN_THOUSAND_HOLLAR * 8) / 100)
        );

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 startBlock = block.number;
        uint256 rateBefore = vault.exchangeRate();
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();
        assertEq(
            block.number,
            startBlock,
            "shock + price-feed-read happen in same block (no smoothing window)"
        );
        assertLt(rateAfter, rateBefore, "rate dropped same block");

        // What an AaveOracle consumer would see if it queried before and
        // after, in the same block:
        uint256 dropBps = ((rateBefore - rateAfter) * 10_000) / rateBefore;
        emit log_named_uint("oracle-readable rate drop in 1 block (bps)", dropBps);
        assertGt(dropBps, 0, "drop > 0 in same block");
    }

    /// @notice Confirms there is no admin lever in `pokeDecentral` to halt
    ///         on large mismatches -- the path proceeds and emits only an
    ///         informational `PrincipalMismatch` event. A real-time monitor
    ///         is the only existing alarm.
    function test_H02_no_circuit_breaker_on_large_mismatch() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        _warpDays(60);

        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // 50% haircut -- catastrophic.
        pool.setPayoutDelta(_tokenIdOf(0), -int256(TEN_THOUSAND_HOLLAR / 2));

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();
        // Does not revert despite a 50% haircut -- vault socialises silently.
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        uint256 dropBps = ((rateBefore - rateAfter) * 10_000) / rateBefore;
        emit log_named_uint("50% haircut -> rate drop (bps)", dropBps);

        // Should be a massive drop with no circuit-breaker in between.
        assertGt(dropBps, 2000, "no circuit breaker on 50% haircut");
    }

    function _tokenIdOf(uint256 positionIndex) internal view returns (uint256) {
        (uint256 tokenId, , , , , ) = vault.getPosition(positionIndex);
        return tokenId;
    }
}
