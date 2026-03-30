// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title Stale Accounting Edge Case Tests
/// @notice Targeted tests to reproduce the invariant fuzzer finding:
///         totalStaleValue mismatch after mark → yield claim → unmark → re-mark cycles.
contract StaleAccountingTest is BaseTest {

    function _makeYieldRequested(uint256 posIdx) internal {
        _warpDays(61);
        vault.pokeDecentral(posIdx);
    }

    function _makeStaleEligible(uint256 posIdx) internal {
        _makeYieldRequested(posIdx);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
    }

    function _markStale(uint256 posIdx) internal {
        vm.prank(admin);
        vault.markPositionStale(posIdx);
    }

    function _unmarkStale(uint256 posIdx, bool backtrack) internal {
        vm.prank(admin);
        vault.unmarkPositionStale(posIdx, backtrack);
    }

    function _approveAndClaimYield(uint256 posIdx) internal {
        (uint256 tokenId, , , , , ) = vault.getPosition(posIdx);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(posIdx);
    }

    function _readStaleFields(uint256 idx) internal view returns (bool isStale, uint256 stalePrincipal, uint256 staleYield) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok, "positions() call failed");
        // 11 fields, each 32 bytes. isStale=word7, stalePrincipal=word8, staleYield=word9
        assembly {
            isStale := mload(add(data, 256))       // 32 + 7*32
            stalePrincipal := mload(add(data, 288)) // 32 + 8*32
            staleYield := mload(add(data, 320))     // 32 + 9*32
        }
    }

    function _checkStaleInvariant() internal view {
        uint256 count = vault.getPositionCount();
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) {
            (, , , , , uint8 state) = vault.getPosition(i);
            (bool isStale, uint256 sp, uint256 sy) = _readStaleFields(i);
            if (state != 4 && isStale) {
                sum += sp + sy;
            }
        }
        assertEq(vault.totalStaleValue(), sum, "totalStaleValue mismatch");
    }

    function _checkInvestedInvariant() internal view {
        uint256 count = vault.getPositionCount();
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) {
            (, uint256 principal, , , , uint8 state) = vault.getPosition(i);
            (bool isStale, , ) = _readStaleFields(i);
            if (state != 4 && !isStale) {
                sum += principal;
            }
        }
        assertEq(vault.totalInvestedPrincipal(), sum, "totalInvestedPrincipal mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   BASIC: mark → unmark cycle (no yield claim in between)
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_basicMarkUnmark() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _makeStaleEligible(0);

        _markStale(0);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        _unmarkStale(0, false);
        _checkStaleInvariant();
        _checkInvestedInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   mark → yield claim while stale → unmark(backtrack=false) → re-mark
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_markYieldClaimUnmarkRemark_noBacktrack() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _makeStaleEligible(0);

        // Step 1: mark stale
        _markStale(0);
        _checkStaleInvariant();

        // Step 2: yield claimed while stale (state → YieldClaimed → PrincipalWithdrawalRequested)
        _approveAndClaimYield(0);
        _checkStaleInvariant();

        // Step 3: unmark with no backtrack
        _unmarkStale(0, false);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Step 4: wait past delay so we can re-mark
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Step 5: re-mark stale
        _markStale(0);
        _checkStaleInvariant();
        _checkInvestedInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   mark → yield claim while stale → unmark(backtrack=true) → re-mark
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_markYieldClaimUnmarkRemark_withBacktrack() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _makeStaleEligible(0);

        _markStale(0);
        _checkStaleInvariant();

        _approveAndClaimYield(0);
        _checkStaleInvariant();

        _unmarkStale(0, true);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        _markStale(0);
        _checkStaleInvariant();
        _checkInvestedInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   TWO POSITIONS: mark both, yield on one, unmark, re-mark
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_twoPositions_interleaved() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        _warpDays(61);
        vault.pokeDecentral(0); // pos 0 → YieldWithdrawalRequested
        vault.pokeDecentral(1); // pos 1 → YieldWithdrawalRequested
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Mark both stale
        _markStale(0);
        _markStale(1);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Yield claim on position 0 only
        (uint256 tokenId0, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId0);
        vault.pokeDecentral(0); // yield on stale pos 0
        _checkStaleInvariant();

        // Unmark position 0
        _unmarkStale(0, false);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Wait, then re-mark position 0
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        _markStale(0);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Now unmark position 1 with backtrack
        _unmarkStale(1, true);
        _checkStaleInvariant();
        _checkInvestedInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   TRIPLE CYCLE: mark → unmark → mark → unmark → mark
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_tripleCycle() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _makeStaleEligible(0);

        // Cycle 1: mark → yield claim → unmark
        _markStale(0);
        _approveAndClaimYield(0);
        _unmarkStale(0, true);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // State is PrincipalWithdrawalRequested, wait past delay
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Cycle 2: mark → unmark (no yield claim this time)
        _markStale(0);
        _checkStaleInvariant();
        _unmarkStale(0, false);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Wait again
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Cycle 3: mark again
        _markStale(0);
        _checkStaleInvariant();
        _checkInvestedInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   STALE POSITION FULLY REDEEMED
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_fullRedemptionThenCheckPhantom() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _makeStaleEligible(0);

        _markStale(0);
        _checkStaleInvariant();

        // Process through to Redeemed while stale
        _approveAndClaimYield(0);
        (uint256 tokenId, , , , , ) = vault.getPosition(0);
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "Redeemed");

        // Phantom state: isStale still true, stalePrincipal still set
        (bool isStale, uint256 sp, ) = _readStaleFields(0);
        assertTrue(isStale, "isStale not cleared on redemption (phantom)");
        assertGt(sp, 0, "stalePrincipal not cleared (phantom)");

        // But totalStaleValue should be 0
        assertEq(vault.totalStaleValue(), 0, "totalStaleValue should be 0 after full redemption");

        // Invariant should still hold because we exclude redeemed positions
        _checkStaleInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   MIXED: deposit, stale, more deposits, process, stale again
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_mixedWithNewDeposits() public {
        // Position 0
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        _markStale(0);
        _checkStaleInvariant();

        // New deposits while position 0 is stale
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Unmark position 0
        _unmarkStale(0, true);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Warp, process position 1
        _warpDays(61);
        vault.pokeDecentral(1); // pos 1 → YieldWithdrawalRequested
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Mark position 1 stale
        _markStale(1);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Re-mark position 0 (still PrincipalWithdrawalRequested from earlier)
        // Need to check if it's eligible
        (, , , , , uint8 state0) = vault.getPosition(0);
        if (state0 >= 1 && state0 <= 3) {
            // If eligible, mark it
            vm.prank(admin);
            try vault.markPositionStale(0) {
                _checkStaleInvariant();
                _checkInvestedInvariant();
            } catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FUZZ: random mark/unmark cycles - let Foundry find the edge case
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_fuzz_markUnmarkCycles(uint8 cycles, bool backtrack) public {
        cycles = uint8(bound(cycles, 1, 10));

        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        for (uint8 i = 0; i < cycles; i++) {
            (, , , , , uint8 state) = vault.getPosition(0);
            if (state == 4) break; // redeemed, stop

            (bool isStale, , ) = _readStaleFields(0);
            if (!isStale && state >= 1 && state <= 3) {
                // Try mark
                vm.prank(admin);
                try vault.markPositionStale(0) {} catch { continue; }
                _checkStaleInvariant();

                // Maybe approve and process
                (uint256 tid, , , , , uint8 s2) = vault.getPosition(0);
                if (s2 == 1) {
                    pool.approveYieldWithdrawal(tid);
                    vault.pokeDecentral(0);
                    _checkStaleInvariant();
                }

                // Unmark
                _unmarkStale(0, backtrack);
                _checkStaleInvariant();
                _checkInvestedInvariant();

                vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
            }
        }

        _checkStaleInvariant();
        _checkInvestedInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  FUZZER PATTERN: many deposits, warps, mark/unmark interleaved
    // ═══════════════════════════════════════════════════════════════════════

    function test_stale_fuzzerPattern() public {
        // Reproduce the pattern from the invariant failure:
        // multiple deposits, warps, marks, unmarks

        // Deposit 3 positions
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);

        // Warp past maturity
        _warpDays(61);

        // Request yield on all
        vault.pokeDecentral(0);
        vault.pokeDecentral(1);
        vault.pokeDecentral(2);

        // Wait past delay
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Mark position 0 stale
        _markStale(0);
        _checkStaleInvariant();

        // Approve and claim yield on position 0 (while stale)
        (uint256 tid0, , , , , ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tid0);
        vault.pokeDecentral(0);
        _checkStaleInvariant();

        // Warp a bit more
        vm.warp(block.timestamp + 10 days);

        // Mark position 1 stale
        _markStale(1);
        _checkStaleInvariant();

        // Unmark position 0 with backtrack=true
        _unmarkStale(0, true);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Unmark position 1 with backtrack=false
        _unmarkStale(1, false);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Warp again
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        // Re-mark position 0 (should be in PrincipalWithdrawalRequested)
        (, , , , , uint8 s0) = vault.getPosition(0);
        if (s0 >= 1 && s0 <= 3) {
            _markStale(0);
            _checkStaleInvariant();
            _checkInvestedInvariant();
        }

        // Mark position 2 stale
        _markStale(2);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Approve yield on position 2 (stale), process
        (uint256 tid2, , , , , ) = vault.getPosition(2);
        pool.approveYieldWithdrawal(tid2);
        vault.pokeDecentral(2);
        _checkStaleInvariant();

        // Approve yield on position 1 (not stale anymore), process
        (uint256 tid1, , , , , ) = vault.getPosition(1);
        pool.approveYieldWithdrawal(tid1);
        vault.pokeDecentral(1);
        _checkStaleInvariant();
        _checkInvestedInvariant();

        // Final comprehensive check
        _checkStaleInvariant();
        _checkInvestedInvariant();
    }
}
