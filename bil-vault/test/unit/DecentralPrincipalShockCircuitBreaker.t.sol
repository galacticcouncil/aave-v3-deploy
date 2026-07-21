// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @notice Audit H-02 mitigation: the circuit breaker added to
///         `pokeDecentral` refuses to atomically socialize a catastrophic
///         Decentral principal haircut into `exchangeRate()`. These tests
///         mirror the scenarios in `DecentralPrincipalShockOracleTest` and
///         prove the breaker fires under each of them (4%, 8%, 10%, 50%
///         haircuts) and that small sub-threshold drift is still tolerated.
contract DecentralPrincipalShockCircuitBreakerTest is BaseTest {
    address public adminAddr;

    function setUp() public override {
        super.setUp();
        adminAddr = admin;
    }

    // ============================================================
    //                  BREAKER FIRES (default 100 bps)
    // ============================================================

    function test_breaker_fires_on_4pct_haircut() public {
        _haircutFires(400, 4); // 4% = 400 bps; 4 used only for label
    }

    function test_breaker_fires_on_8pct_haircut() public {
        _haircutFires(800, 8);
    }

    function test_breaker_fires_on_10pct_haircut() public {
        _haircutFires(1000, 10);
    }

    function test_breaker_fires_on_50pct_haircut() public {
        _haircutFires(5000, 50);
    }

    /// @notice 0.5% haircut is below the default 1% (100 bps) threshold and
    ///         must NOT trip the breaker — the existing socialization path
    ///         still absorbs small drift quietly.
    function test_breaker_does_not_fire_on_sub_threshold_haircut() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        _warpDays(60);

        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // 0.5% haircut = 50 bps, below the 100 bps default.
        int256 haircut = -int256((TEN_THOUSAND_HOLLAR * 50) / 10_000);
        pool.setPayoutDelta(_tokenIdOf(0), haircut);

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();
        // No revert.
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        // Rate did move (drift was real) but the breaker tolerated it.
        assertLt(rateAfter, rateBefore, "sub-threshold haircut still socialized");
        uint256 dropBps = ((rateBefore - rateAfter) * 10_000) / rateBefore;
        emit log_named_uint("sub-threshold drop (bps)", dropBps);
    }

    /// @notice A principal *surplus* (Decentral overpays) is benign and must
    ///         NOT trip the breaker — it lifts the exchange rate.
    function test_breaker_does_not_fire_on_surplus() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        _warpDays(60);
        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // +5% surplus -- way above the threshold but in the benign direction.
        pool.setPayoutDelta(_tokenIdOf(0), int256(TEN_THOUSAND_HOLLAR / 20));
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        assertGt(rateAfter, rateBefore, "surplus lifts rate");
    }

    // ============================================================
    //                      ADMIN SETTER
    // ============================================================

    function test_default_threshold_is_100_bps() public {
        assertEq(vault.principalMismatchBpsThreshold(), 100);
    }

    function test_setter_emits_event_and_updates_state() public {
        vm.expectEmit(true, true, true, true);
        emit BILVault.PrincipalMismatchBpsUpdated(100, 250);
        vm.prank(adminAddr);
        vault.setPrincipalMismatchBpsThreshold(250);
        assertEq(vault.principalMismatchBpsThreshold(), 250);
    }

    function test_setter_rejects_above_max() public {
        vm.prank(adminAddr);
        vm.expectRevert(BILVault.BpsAboveMax.selector);
        vault.setPrincipalMismatchBpsThreshold(10_001);
    }

    function test_setter_accepts_max_disable() public {
        vm.prank(adminAddr);
        vault.setPrincipalMismatchBpsThreshold(10_000);
        assertEq(vault.principalMismatchBpsThreshold(), 10_000);
    }

    function test_setter_only_admin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setPrincipalMismatchBpsThreshold(500);
    }

    /// @notice Raising the threshold above the actual shortfall lets the
    ///         once-blocked withdrawal go through. Useful escape hatch for
    ///         ops once they've assessed the Decentral situation and accept
    ///         the haircut.
    function test_admin_can_raise_threshold_to_tolerate_haircut() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        _warpDays(60);
        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        // 4% haircut.
        pool.setPayoutDelta(_tokenIdOf(0), -int256((TEN_THOUSAND_HOLLAR * 4) / 100));
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // First attempt reverts (4% > 1% default).
        vm.expectRevert();
        vault.pokeDecentral(0);

        // Ops raise threshold to 5% (500 bps).
        vm.prank(adminAddr);
        vault.setPrincipalMismatchBpsThreshold(500);

        // Now succeeds.
        vault.pokeDecentral(0);
    }

    // ============================================================
    //                          HELPERS
    // ============================================================

    /// @dev Replays the PoC scenario: three equal positions, mature one,
    ///      apply a haircut sized in bps of principal, then assert the
    ///      breaker reverts pokeDecentral (instead of silently absorbing).
    /// @param haircutBps Size of haircut in bps of principal (e.g., 400 = 4%).
    /// @param pctLabel   Percentage label for logs.
    function _haircutFires(uint256 haircutBps, uint256 pctLabel) internal {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        _warpDays(60);

        vault.pokeDecentral(0);
        pool.approveYieldWithdrawal(_tokenIdOf(0));
        vault.pokeDecentral(0);
        pool.approvePrincipalWithdrawal(_tokenIdOf(0));

        int256 haircut = -int256((TEN_THOUSAND_HOLLAR * haircutBps) / 10_000);
        pool.setPayoutDelta(_tokenIdOf(0), haircut);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        uint256 rateBefore = vault.exchangeRate();

        // Expect the typed revert with the exact computed shortfall in bps.
        // Since the haircut is sized as bps of principal and principal is
        // exactly TEN_THOUSAND_HOLLAR, the shortfall bps == haircutBps.
        vm.expectRevert(
            abi.encodeWithSelector(
                BILVault.PrincipalDriftTooLarge.selector,
                uint256(0),
                TEN_THOUSAND_HOLLAR,
                TEN_THOUSAND_HOLLAR - uint256(-haircut),
                haircutBps
            )
        );
        vault.pokeDecentral(0);

        // Rate is unchanged -- the whole tx reverted, no socialization.
        uint256 rateAfter = vault.exchangeRate();
        assertEq(rateAfter, rateBefore, "rate not shocked when breaker fires");
        emit log_named_uint("breaker fired on haircut pct", pctLabel);
    }

    function _tokenIdOf(uint256 positionIndex) internal view returns (uint256) {
        (uint256 tokenId, , , , ,,,,) = vault.getPosition(positionIndex);
        return tokenId;
    }
}
