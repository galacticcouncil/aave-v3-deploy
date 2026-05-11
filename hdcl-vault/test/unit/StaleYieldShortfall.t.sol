// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Stale Yield Shortfall Write-off Visibility
/// @notice Verifies the new StaleYieldShortfallWritten event fires when
///         unmarkPositionStale is called on a YC/PWR-state position whose
///         staleYield has a residual (Decentral underpaid in a stale
///         yield-execute earlier). The loss is socialized into totalAssets
///         (no real HOLLAR to recover) but is no longer silent.
contract StaleYieldShortfallTest is BaseTest {
    bytes32 internal constant SHORTFALL_TOPIC =
        keccak256("StaleYieldShortfallWritten(uint256,uint256)");

    function _shortfallPayload() internal returns (bool found, uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != SHORTFALL_TOPIC) continue;
            amount = abi.decode(logs[i].data, (uint256));
            return (true, amount);
        }
        return (false, 0);
    }

    function _readStaleYield(uint256 idx) internal view returns (uint256 sy) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok);
        assembly { sy := mload(add(data, 320)) }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   NORMAL CASE: no shortfall → no event
    // ═══════════════════════════════════════════════════════════════════════

    function test_unmarkOnYC_noEvent_whenStaleYieldZero() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        // Decentral pays in full (no yield delta)
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        // staleYield == 0 after this (Decentral paid >= staleYield)
        assertEq(_readStaleYield(0), 0, "staleYield fully paid down");

        vm.recordLogs();
        vm.prank(admin);
        vault.unmarkPositionStale(0);

        (bool found, ) = _shortfallPayload();
        assertFalse(found, "no event when no residual");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   SHORTFALL CASE: Decentral underpays → unmark emits event
    // ═══════════════════════════════════════════════════════════════════════

    function test_unmarkOnYCorPWR_emitsEvent_whenResidualExists() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0); // → YWR
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        // Inject a Decentral yield underpayment of 100 wei
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.setYieldDelta(tokenId, -100);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        // After the stale yield-claim, residual staleYield = 100 wei
        // (deduction = min(staleYield, yieldReceived); yieldReceived was
        // 100 less than staleYield, so 100 stays)
        uint256 residual = _readStaleYield(0);
        assertEq(residual, 100, "residual = injected shortfall");

        vm.recordLogs();
        vm.prank(admin);
        vault.unmarkPositionStale(0);

        (bool found, uint256 amount) = _shortfallPayload();
        assertTrue(found, "shortfall event must fire");
        assertEq(amount, 100, "event payload matches residual");

        // staleYield cleared after unmark
        assertEq(_readStaleYield(0), 0, "staleYield zeroed");
    }

    /// @notice A larger shortfall scenario showing the totalAssets impact.
    function test_unmarkOnYCorPWR_socializesResidualLoss() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.setYieldDelta(tokenId, -50e18); // 50 HOLLAR shortfall
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 residual = _readStaleYield(0);
        assertGt(residual, 0, "residual exists");

        vm.prank(admin);
        vault.unmarkPositionStale(0);

        // totalAssets dropped by exactly the residual amount (socialized loss)
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(
            totalAssetsBefore - totalAssetsAfter,
            residual,
            "totalAssets drops by residual"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   AUDIT FINDING #3 — keeper-driven write-off must also emit the event
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Drive a stale position through the FULL keeper lifecycle (without
    ///      admin unmark) — yield-execute underpays, PWR → Redeemed absorbs
    ///      the residual. Returns the residual amount that ends up written
    ///      off at PWR → Redeemed.
    function _staleThroughRedeemed(int256 yieldShortfallWei)
        internal
        returns (uint256 residual)
    {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0); // Active → YWR
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        // Inject Decentral yield underpayment.
        pool.setYieldDelta(tokenId, yieldShortfallWei);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0); // YWR → YieldClaimed (stale path, residual staleYield)

        residual = _readStaleYield(0);

        // Continue to PWR → Redeemed without admin intervention.
        vault.pokeDecentral(0); // YieldClaimed → PWR
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        // The next pokeDecentral fires PWR → Redeemed, which is the call we
        // record logs around in the caller.
    }

    /// @notice Pre-fix, the residual staleYield was silently absorbed at
    ///         PWR → Redeemed (only the admin-unmark path emitted the event).
    ///         Post-fix, both paths emit the same event with the same payload.
    function test_pokeDecentral_PWRtoRedeemed_emitsShortfall() public {
        uint256 residual = _staleThroughRedeemed(-100); // 100 wei underpaid

        vm.recordLogs();
        vault.pokeDecentral(0); // PWR → Redeemed

        (bool found, uint256 amount) = _shortfallPayload();
        assertTrue(found, "keeper-driven write-off must emit event");
        assertEq(amount, residual, "event payload matches residual");
        assertEq(amount, 100, "residual = injected shortfall");
    }

    /// @notice Keeper-driven path with no Decentral underpayment — the
    ///         residual is zero, so the event must NOT fire (otherwise the
    ///         signal becomes noise for every stale redemption).
    function test_pokeDecentral_PWRtoRedeemed_noEvent_whenStaleYieldZero() public {
        _staleThroughRedeemed(0); // Decentral pays in full
        assertEq(_readStaleYield(0), 0, "no residual after full payment");

        vm.recordLogs();
        vault.pokeDecentral(0); // PWR → Redeemed

        (bool found, ) = _shortfallPayload();
        assertFalse(found, "no event when no residual");
    }

    /// @notice Larger keeper-driven shortfall — confirms the totalAssets
    ///         impact matches the event payload, identical semantics to the
    ///         admin-unmark variant above.
    function test_pokeDecentral_PWRtoRedeemed_socializesResidualLoss() public {
        uint256 residual = _staleThroughRedeemed(-50e18); // 50 HOLLAR shortfall
        assertGt(residual, 0, "residual exists after stale yield-execute");

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.recordLogs();
        vault.pokeDecentral(0); // PWR → Redeemed

        (bool found, uint256 amount) = _shortfallPayload();
        assertTrue(found, "event fires");
        assertEq(amount, residual, "event amount = residual");

        // totalAssets drops by the residual: principal arrives in idleHollar
        // (so principal portion is net zero), and the residual staleYield is
        // the only thing leaving totalAssets without arriving anywhere else.
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(
            totalAssetsBefore - totalAssetsAfter,
            residual,
            "totalAssets drops by residual"
        );
    }
}
