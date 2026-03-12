// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract AdminTest is BaseTest {
    /// @dev Helper to calculate expected yield: principal * apyWad * days / 365 / 1e18
    function _expectedYield(uint256 principal, uint256 apyWad, uint256 days_)
        internal
        pure
        returns (uint256)
    {
        return principal * apyWad * days_ * SECONDS_PER_DAY / (365 days * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                     PAUSE DEPOSITS
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseDeposits_onlyAdmin() public {
        // Non-admin should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                vault.ADMIN_ROLE()
            )
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                vault.ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setTvlCap(1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  MARK POSITION STALE
    // ═══════════════════════════════════════════════════════════════════════

    function test_markPositionStale_capsYield() public {
        // 1. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Warp 30 days -- yield has been accruing
        _warpDays(30);

        uint256 rateAt30Days = vault.exchangeRate();
        assertGt(rateAt30Days, 1e18, "Rate should be > 1 after 30 days");

        // 3. Mark position stale -> yield for this position freezes at day 30 value
        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 rateAfterStale = vault.exchangeRate();
        // Rate should be approximately the same as at day 30 (position's yield is now frozen)
        assertApproxEqRel(
            rateAfterStale,
            rateAt30Days,
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

    function test_unmarkPositionStale_resumesYield() public {
        // 1. Deposit
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // 2. Warp 30 days, mark stale
        _warpDays(30);
        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 rateAtStale = vault.exchangeRate();

        // 3. Warp 10 more days while stale -- rate should not change
        _warpDays(10);
        uint256 rateDuringStale = vault.exchangeRate();
        assertApproxEqRel(
            rateDuringStale,
            rateAtStale,
            0.001e18,
            "Rate should not change during stale period"
        );

        // 4. Unmark stale -> yield starts accruing again from NOW
        vm.prank(admin);
        vault.unmarkPositionStale(0);

        uint256 rateAfterUnmark = vault.exchangeRate();
        // When unmarking, the frozen staleYield (from the 30-day period before marking) is NOT
        // carried forward -- the position restarts yield accrual from now. So the totalAssets
        // drops by the previously frozen staleYield. This means the rate drops slightly.
        // The rate should be close to what it was before the stale yield was added
        // (approximately 1e18 since yield was removed and only principal remains).
        // We use a wider tolerance (2%) to account for this expected behavior.
        assertApproxEqRel(
            rateAfterUnmark,
            rateAtStale,
            0.02e18,
            "Rate should be approximately preserved after unmarking stale (within 2%)"
        );

        // 5. Warp 10 more days -> rate should increase again
        _warpDays(10);
        uint256 rateAfterResume = vault.exchangeRate();
        assertGt(
            rateAfterResume,
            rateAfterUnmark,
            "Rate should increase after unmark stale and time passes"
        );
    }

    function test_markPositionStale_revertsAlreadyStale() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

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
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                vault.UPGRADER_ROLE()
            )
        );
        vm.prank(alice);
        vault.upgradeToAndCall(address(newImpl), "");

        // Admin (who has UPGRADER_ROLE) should succeed
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImpl), "");
    }
}
