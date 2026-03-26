// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract AdminTest is BaseTest {
    /// @dev Helper to calculate expected yield: principal * apyWad * days / 365 / 1e18
    function _expectedYield(uint256 principal, uint256 apyWad, uint256 days_)
        internal
        pure
        returns (uint256)
    {
        return principal * apyWad * days_ * SECONDS_PER_DAY / (365 days * 1e18);
    }

    /// @dev Build OZ v4 AccessControl revert string
    function _accessControlRevert(address account, bytes32 role) internal pure returns (bytes memory) {
        return bytes(string(abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        )));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     PAUSE DEPOSITS
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseDeposits_onlyAdmin() public {
        // Non-admin should revert
        vm.expectRevert(_accessControlRevert(alice, vault.ADMIN_ROLE()));
        vm.prank(alice);
        vault.pauseDeposits();
    }

    function test_pauseDeposits_blocksDeposits() public {
        // Admin pauses deposits
        vm.prank(admin);
        vault.pauseDeposits();

        assertTrue(vault.depositsPaused(), "depositsPaused should be true");

        // Alice tries to deposit -- should revert
        vm.expectRevert(HDCLVault.DepositsArePaused.selector);
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Admin unpauses
        vm.prank(admin);
        vault.unpauseDeposits();

        assertFalse(vault.depositsPaused(), "depositsPaused should be false");

        // Deposit should work now
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertGt(hdcl, 0, "Deposit should succeed after unpause");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     SET TVL CAP
    // ═══════════════════════════════════════════════════════════════════════

    function test_setTvlCap_updatesValue() public {
        uint256 newCap = 5_000_000e18;

        vm.prank(admin);
        vault.setTvlCap(newCap);

        assertEq(vault.tvlCap(), newCap, "TVL cap should be updated");
    }

    function test_setTvlCap_onlyAdmin() public {
        vm.expectRevert(_accessControlRevert(alice, vault.ADMIN_ROLE()));
        vm.prank(alice);
        vault.setTvlCap(1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  MARK POSITION STALE
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Helper: advance position to YieldWithdrawalRequested and warp past withdrawalDelay
    function _makePositionStaleEligible(uint256 positionIndex) internal {
        // Warp past maturity so pokeDecentral advances to YieldWithdrawalRequested
        _warpDays(60);
        vault.pokeDecentral(positionIndex);
        // Warp past withdrawalDelay (48h) so markPositionStale is allowed
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
    }

    function test_markPositionStale_capsYield() public {
        // 1. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Advance to YieldWithdrawalRequested + wait past withdrawalDelay
        _makePositionStaleEligible(0);

        uint256 rateBeforeStale = vault.exchangeRate();
        assertGt(rateBeforeStale, 1e18, "Rate should be > 1 after yield accrual");

        // 3. Mark position stale -> yield freezes at current value
        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 rateAfterStale = vault.exchangeRate();
        assertApproxEqRel(
            rateAfterStale,
            rateBeforeStale,
            0.001e18,
            "Rate should be preserved immediately after marking stale"
        );

        // 4. Warp 30 more days -> rate should NOT increase since the only position is stale
        _warpDays(30);

        uint256 rateAfterMore = vault.exchangeRate();
        assertApproxEqRel(
            rateAfterMore,
            rateAfterStale,
            0.001e18,
            "Rate should NOT increase while position is stale"
        );
    }

    function test_markPositionStale_revertsOnActivePosition() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        // Position is still Active -- should revert
        vm.prank(admin);
        vm.expectRevert(HDCLVault.PositionNotStuckLongEnough.selector);
        vault.markPositionStale(0);
    }

    function test_markPositionStale_revertsBeforeDelay() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        // Advance to YieldWithdrawalRequested but do NOT wait past withdrawalDelay
        _warpDays(60);
        vault.pokeDecentral(0);

        vm.prank(admin);
        vm.expectRevert(HDCLVault.PositionNotStuckLongEnough.selector);
        vault.markPositionStale(0);
    }

    function test_unmarkPositionStale_resetYield() public {
        // 1. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Advance to stale-eligible and mark stale
        _makePositionStaleEligible(0);
        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 rateAtStale = vault.exchangeRate();

        // 3. Warp 10 more days while stale -- rate should not change
        _warpDays(10);
        assertApproxEqRel(
            vault.exchangeRate(),
            rateAtStale,
            0.001e18,
            "Rate should not change during stale period"
        );

        // 4. Unmark stale with backtrackYield=false -> yield restarts from now (pre-stale yield lost)
        vm.prank(admin);
        vault.unmarkPositionStale(0, false);

        // 5. Warp 10 more days -> rate should increase again
        _warpDays(10);
        uint256 rateAfterResume = vault.exchangeRate();
        assertGt(
            rateAfterResume,
            vault.exchangeRate() - 1, // just check it's growing
            "Rate should increase after unmark stale and time passes"
        );
    }

    function test_unmarkPositionStale_backtrackYield() public {
        // 1. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Advance to stale-eligible and mark stale
        _makePositionStaleEligible(0);

        uint256 rateBeforeStale = vault.exchangeRate();
        vm.prank(admin);
        vault.markPositionStale(0);

        // 3. Unmark with backtrackYield=true -> pre-stale yield is preserved
        vm.prank(admin);
        vault.unmarkPositionStale(0, true);

        uint256 rateAfterUnmark = vault.exchangeRate();
        // Rate should be approximately the same as before stale (yield preserved)
        assertApproxEqRel(
            rateAfterUnmark,
            rateBeforeStale,
            0.001e18,
            "Rate should be preserved when backtracking yield"
        );
    }

    function test_markPositionStale_revertsAlreadyStale() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _makePositionStaleEligible(0);

        // Mark stale once
        vm.prank(admin);
        vault.markPositionStale(0);

        // Mark stale again -- should revert
        vm.prank(admin);
        vm.expectRevert(HDCLVault.PositionAlreadyStale.selector);
        vault.markPositionStale(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   UPGRADE AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgrade_onlyUpgrader() public {
        // Deploy a new implementation
        HDCLVault newImpl = new HDCLVault();

        // Non-upgrader should revert
        vm.expectRevert(_accessControlRevert(alice, vault.UPGRADER_ROLE()));
        vm.prank(alice);
        vault.upgradeTo(address(newImpl));

        // Admin (who has UPGRADER_ROLE) should succeed
        vm.prank(admin);
        vault.upgradeTo(address(newImpl));
    }
}
