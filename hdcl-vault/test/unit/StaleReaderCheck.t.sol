// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @notice Verify that reading stale fields from positions() works correctly.
///         If the reader is broken, our invariant is testing garbage.
contract StaleReaderCheckTest is BaseTest {

    function _readViaAssembly(uint256 idx) internal view returns (
        bool isStale, uint256 stalePrincipal, uint256 staleYield
    ) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok && data.length >= 352, "staticcall failed");
        assembly {
            isStale := mload(add(data, 256))
            stalePrincipal := mload(add(data, 288))
            staleYield := mload(add(data, 320))
        }
    }

    /// @notice Verify reader against known stale state
    function test_readerAccuracy_stalePosition() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        // Read via assembly
        (bool isStale, uint256 sp, uint256 sy) = _readViaAssembly(0);
        assertTrue(isStale, "Assembly: isStale should be true");
        assertEq(sp, TEN_THOUSAND_HOLLAR, "Assembly: stalePrincipal should be 10k");
        assertGt(sy, 0, "Assembly: staleYield should be > 0");

        // Cross-check: totalStaleValue should equal sp + sy
        assertEq(vault.totalStaleValue(), sp + sy, "totalStaleValue == sp + sy");
    }

    /// @notice Verify reader on non-stale position
    function test_readerAccuracy_nonStalePosition() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        (bool isStale, uint256 sp, uint256 sy) = _readViaAssembly(0);
        assertFalse(isStale, "Assembly: isStale should be false");
        assertEq(sp, 0, "Assembly: stalePrincipal should be 0");
        assertEq(sy, 0, "Assembly: staleYield should be 0");
    }

    /// @notice Verify reader after unmark
    function test_readerAccuracy_afterUnmark() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        vm.prank(admin);
        vault.unmarkPositionStale(0);

        (bool isStale, uint256 sp, uint256 sy) = _readViaAssembly(0);
        assertFalse(isStale, "Assembly: isStale false after unmark");
        assertEq(sp, 0, "Assembly: stalePrincipal cleared");
        assertEq(sy, 0, "Assembly: staleYield cleared");
        assertEq(vault.totalStaleValue(), 0, "totalStaleValue zeroed");
    }

    /// @notice Verify reader after yield claim on stale position
    function test_readerAccuracy_afterYieldClaimWhileStale() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 staleValueBefore = vault.totalStaleValue();
        (, , uint256 syBefore) = _readViaAssembly(0);

        // Execute yield on stale
        (uint256 tokenId, , , , ,) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0);

        (bool isStale, uint256 sp, uint256 sy) = _readViaAssembly(0);
        assertTrue(isStale, "Still stale after yield claim");
        assertEq(sp, TEN_THOUSAND_HOLLAR, "stalePrincipal unchanged");
        assertLe(sy, syBefore, "staleYield decreased or same");

        // Key check: totalStaleValue == sp + sy
        assertEq(vault.totalStaleValue(), sp + sy, "totalStaleValue consistent after yield claim");
    }

    /// @notice CRITICAL: reproduce the exact pattern — mark, yield, unmark(backtrack=true), re-mark
    ///         Check at EVERY step
    function test_readerAccuracy_fullCycleStepByStep() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // === MARK ===
        vm.prank(admin);
        vault.markPositionStale(0);

        (bool s1, uint256 sp1, uint256 sy1) = _readViaAssembly(0);
        assertTrue(s1);
        uint256 tv1 = vault.totalStaleValue();
        assertEq(tv1, sp1 + sy1, "Step 1: mark stale consistent");

        // === YIELD CLAIM ===
        (uint256 tid, , , , ,) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tid);
        vault.pokeDecentral(0);

        (bool s2, uint256 sp2, uint256 sy2) = _readViaAssembly(0);
        assertTrue(s2);
        uint256 tv2 = vault.totalStaleValue();
        assertEq(tv2, sp2 + sy2, "Step 2: yield claim consistent");

        // === UNMARK (backtrack=true) ===
        vm.prank(admin);
        vault.unmarkPositionStale(0);

        (bool s3, uint256 sp3, uint256 sy3) = _readViaAssembly(0);
        assertFalse(s3);
        assertEq(sp3, 0);
        assertEq(sy3, 0);
        assertEq(vault.totalStaleValue(), 0, "Step 3: unmark zeroed");
        assertEq(vault.totalInvestedPrincipal(), TEN_THOUSAND_HOLLAR, "Step 3: back in bucket");

        // === WARP + RE-MARK ===
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        (bool s4, uint256 sp4, uint256 sy4) = _readViaAssembly(0);
        assertTrue(s4);
        uint256 tv4 = vault.totalStaleValue();
        assertEq(tv4, sp4 + sy4, "Step 4: re-mark consistent");
        assertEq(vault.totalInvestedPrincipal(), 0, "Step 4: removed from bucket");
    }

    /// @notice Now try with TWO positions and interleaving
    function test_readerAccuracy_twoPositions_crossCheck() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR); // pos 0
        _deposit(bob, TEN_THOUSAND_HOLLAR);   // pos 1
        _warpDays(61);
        vault.pokeDecentral(0);
        vault.pokeDecentral(1);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Mark both
        vm.prank(admin);
        vault.markPositionStale(0);
        vm.prank(admin);
        vault.markPositionStale(1);

        _assertGlobalConsistency("After marking both");

        // Yield on pos 0 only
        (uint256 tid0, , , , ,) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tid0);
        vault.pokeDecentral(0);
        _assertGlobalConsistency("After yield on pos 0");

        // Unmark pos 0 (backtrack=true)
        vm.prank(admin);
        vault.unmarkPositionStale(0);
        _assertGlobalConsistency("After unmark pos 0");

        // Wait, re-mark pos 0
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        vm.prank(admin);
        vault.markPositionStale(0);
        _assertGlobalConsistency("After re-mark pos 0");

        // Unmark pos 1 (backtrack=false)
        vm.prank(admin);
        vault.unmarkPositionStale(1);
        _assertGlobalConsistency("After unmark pos 1");

        // Yield on pos 1 (normal path now, not stale)
        (uint256 tid1, , , , ,) = vault.getPosition(1);
        pool.approveYieldWithdrawal(tid1);
        vault.pokeDecentral(1);
        _assertGlobalConsistency("After yield on pos 1 (non-stale)");
    }

    function _assertGlobalConsistency(string memory label) internal view {
        uint256 count = vault.getPositionCount();
        uint256 sumStale = 0;
        uint256 sumInvested = 0;
        for (uint256 i = 0; i < count; i++) {
            (, uint256 principal, , , , uint8 state) = vault.getPosition(i);
            (bool isStale, uint256 sp, uint256 sy) = _readViaAssembly(i);
            if (state != 4) {
                if (isStale) {
                    sumStale += sp + sy;
                } else {
                    sumInvested += principal;
                }
            }
        }
        assertEq(vault.totalStaleValue(), sumStale, string.concat(label, ": totalStaleValue"));
        assertEq(vault.totalInvestedPrincipal(), sumInvested, string.concat(label, ": totalInvestedPrincipal"));
    }
}
