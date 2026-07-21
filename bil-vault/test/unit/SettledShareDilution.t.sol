// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @title PoC — Pashov High: settled shares dilute the active exchange rate
/// @notice The finding assumes active shares keep earning while settled shares
///         are fixed. This vault caps Decentral yield at each position's
///         maturity (H-01 fix), so an active position only keeps accruing
///         until IT matures. This test builds the strongest case for the
///         finding: an active holder (bob) whose position is STILL accruing
///         AFTER the attacker's request has settled, and measures whether the
///         blended exchangeRate() is depressed below the true active rate.
contract SettledShareDilutionTest is BaseTest {
    address public attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        hollar.mint(attacker, 1_000_000e18);
        vm.prank(attacker);
        hollar.approve(address(vault), type(uint256).max);
    }

    function test_stagger_settledLingers_whileActiveStillAccrues() public {
        // ── phase 1: attacker gets settled shares, funded by a matured pos ──
        _deposit(attacker, TEN_THOUSAND_HOLLAR);        // position 0
        uint256 reqId = _requestRedeem(attacker, vault.balanceOf(attacker));
        _deposit(charlie, TEN_THOUSAND_HOLLAR);         // position 1, funds settlement

        _warpDays(61);                                  // pos 0 & 1 mature
        _processPositionFull(0);                        // clear backlog: pos 0
        _processPositionFull(1);                        // clear backlog: pos 1 -> idle
        vault.pokeQueue();                              // settle attacker at rate_settle

        (, , uint256 settled, uint256 owed, ) = vault.getRedemptionRequest(reqId);
        assertGt(settled, 0, "attacker settled");
        emit log_named_decimal_uint("settled shares    ", settled, 18);
        emit log_named_decimal_uint("hollarOwed (fixed)", owed, 18);
        emit log_named_decimal_uint("rate @ settle     ", vault.exchangeRate(), 18);

        // Backlog is now clear (0 & 1 redeemed) so bob CAN deposit.
        // ── phase 2: bob opens a fresh active position that keeps accruing ──
        _deposit(bob, TEN_THOUSAND_HOLLAR);             // position 2, fresh
        _warpDays(30);                                  // < 60d maturity: still accruing

        uint256 reported = vault.exchangeRate();
        uint256 activeAssets = vault.totalAssets() - vault.totalReservedHollar();
        uint256 activeSupply = vault.totalSupply() - settled;
        uint256 trueRate = (activeAssets * 1e18) / activeSupply;

        emit log_named_decimal_uint("reported rate     ", reported, 18);
        emit log_named_decimal_uint("true active rate  ", trueRate, 18);

        // FIX: exchangeRate() now prices the ACTIVE pool only, so the
        // reported rate equals the true active rate (±1 wei rounding).
        assertApproxEqAbs(reported, trueRate, 2, "reported must track true active rate");

        // And a fresh deposit is quoted at the true active rate — no free
        // extra shares skimmed from active holders.
        uint256 sharesQuoted = vault.previewDeposit(1_000e18);
        uint256 sharesAtTrue = (1_000e18 * 1e18) / trueRate;
        assertApproxEqRel(sharesQuoted, sharesAtTrue, 1e12, "deposit quote at true active rate");
    }
}

// Standalone round-trip in a second file-scope contract would duplicate setup;
// instead re-run the extraction inline here.
contract SettledShareExtractionTest is BaseTest {
    address public attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        hollar.mint(attacker, 2_000_000e18);
        vm.prank(attacker);
        hollar.approve(address(vault), type(uint256).max);
    }

    function test_roundTripProfitAndActiveHolderLoss() public {
        // attacker acquires lingering settled shares (funded by a matured pos)
        _deposit(attacker, TEN_THOUSAND_HOLLAR);
        uint256 reqId = _requestRedeem(attacker, vault.balanceOf(attacker));
        _deposit(charlie, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1);
        vault.pokeQueue();
        (, , uint256 settled, uint256 owed, ) = vault.getRedemptionRequest(reqId);

        // bob: honest active holder, fresh position still accruing
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        // bob's fair value at the TRUE active rate, pre-attack
        uint256 aA = vault.totalAssets() - vault.totalReservedHollar();
        uint256 aS = vault.totalSupply() - settled;
        uint256 bobFairBefore = (vault.balanceOf(bob) * aA) / aS;

        // ── attack: deposit at depressed rate, then claim to pop the rate ──
        uint256 hBefore = hollar.balanceOf(attacker);
        vm.prank(attacker);
        uint256 fresh = vault.deposit(100_000e18, attacker);
        vm.prank(attacker);
        vault.redeem(settled, attacker, attacker); // burns settled, removes reserve

        // mark fresh shares at post-claim rate (attacker can exit via pool/queue at this rate)
        uint256 freshValue = (fresh * vault.exchangeRate()) / 1e18;
        uint256 hAfter = hollar.balanceOf(attacker);
        // net HOLLAR the attacker put in = (deposit) - (settled claim received)
        uint256 netIn = hBefore - hAfter;
        int256 profit = int256(freshValue) - int256(netIn);

        emit log_named_decimal_uint("settled claim (owed)", owed, 18);
        emit log_named_decimal_uint("net HOLLAR in        ", netIn, 18);
        emit log_named_decimal_uint("fresh shares value   ", freshValue, 18);
        emit log_named_decimal_int("ATTACKER PROFIT      ", profit, 18);

        uint256 bobFairAfter = (vault.balanceOf(bob) * vault.exchangeRate()) / 1e18;
        emit log_named_decimal_uint("bob fair before      ", bobFairBefore, 18);
        emit log_named_decimal_uint("bob fair after       ", bobFairAfter, 18);
        if (bobFairBefore > bobFairAfter) {
            emit log_named_decimal_uint("BOB LOSS             ", bobFairBefore - bobFairAfter, 18);
        }
    }
}
