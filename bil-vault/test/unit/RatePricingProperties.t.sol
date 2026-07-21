// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @title Ground-truth pricing properties (fuzzed)
/// @notice The settled-share dilution (Pashov High) is a PRICING error, which
///         a self-referential invariant can't catch — the price is defined by
///         the state it would check. These fuzz tests use external ground
///         truth instead: (1) settlement must not move the rate, and (2) a
///         fresh deposit must be priced at the active NAV regardless of how
///         many settled shares linger.
contract RatePricingPropertiesTest is BaseTest {
    address public attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        hollar.mint(attacker, 5_000_000e18);
        vm.prank(attacker);
        hollar.approve(address(vault), type(uint256).max);
        // BaseTest funds alice/bob/charlie with modest balances; top them up
        // so the fuzz bounds below fit (approvals already max from BaseTest).
        hollar.mint(alice, 1_000_000e18);
        hollar.mint(bob, 1_000_000e18);
        hollar.mint(charlie, 1_000_000e18);
    }

    /// @notice Settling a queued request never changes exchangeRate(): a
    ///         share settles at exactly the active rate, so removing
    ///         (shares, shares×rate) from the active pool is rate-neutral.
    function testFuzz_settlementIsRateNeutral(
        uint256 depFund,
        uint256 depActive,
        uint256 depQueued
    ) public {
        depFund = bound(depFund, 100e18, 400_000e18);
        depActive = bound(depActive, 100e18, 400_000e18);
        depQueued = bound(depQueued, 100e18, 400_000e18);

        _deposit(alice, depFund);          // position 0 — funds settlement
        _deposit(bob, depActive);          // position 1 — stays active holder
        _deposit(charlie, depQueued);      // position 2 — will queue
        uint256 rid = _requestRedeem(charlie, vault.balanceOf(charlie));

        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1);
        _processPositionFull(2);
        vault.syncMaturities(50);          // absorb maturity effects up front

        uint256 rateBefore = vault.exchangeRate();
        vault.pokeQueue();                 // <-- the settlement step under test
        uint256 rateAfter = vault.exchangeRate();

        // rid consumed; silence
        rid;
        assertApproxEqAbs(rateAfter, rateBefore, 2, "settlement moved the rate");
    }

    /// @notice A fresh deposit is priced at the ACTIVE NAV — the shares minted
    ///         equal assets / active-rate — no matter how large the lingering
    ///         settled balance is. Pre-fix this over-minted at a depressed
    ///         blended rate (the dilution).
    function testFuzz_freshDepositPricedAtActiveNav(
        uint256 settledSize,
        uint256 warp,
        uint256 freshDeposit
    ) public {
        settledSize = bound(settledSize, 100e18, 300_000e18);
        warp = bound(warp, 1 days, 59 days);
        freshDeposit = bound(freshDeposit, 100e18, 400_000e18);

        // attacker acquires lingering settled shares (funded by a matured pos)
        _deposit(attacker, settledSize);
        uint256 rid = _requestRedeem(attacker, vault.balanceOf(attacker));
        _deposit(charlie, settledSize);
        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1);
        vault.pokeQueue();                 // settle attacker
        (, , uint256 settled, , ) = vault.getRedemptionRequest(rid);
        assertGt(settled, 0, "fixture: settled");

        // bob opens a fresh active position that keeps accruing
        _deposit(bob, settledSize);
        vm.warp(block.timestamp + warp);   // active yield accrues, settled lingers

        // Ground truth: shares a fresh deposit SHOULD get = assets / active-rate
        uint256 activeAssets = vault.totalAssets() - vault.totalReservedHollar();
        uint256 activeSupply = vault.totalSupply() - vault.totalSettledBil();
        uint256 expected = (freshDeposit * activeSupply) / activeAssets;

        uint256 got = vault.previewDeposit(freshDeposit);
        assertApproxEqRel(got, expected, 1e12, "fresh deposit not priced at active NAV");

        // And the actually-minted shares match the preview.
        vm.prank(attacker);
        uint256 minted = vault.deposit(freshDeposit, attacker);
        assertEq(minted, got, "minted != previewed");
    }
}
