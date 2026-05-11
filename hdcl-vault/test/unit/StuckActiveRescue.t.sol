// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Active-State Rescue Path
/// @notice Verifies pokeDecentral handles a Decentral revert on Active->YWR
///         without bricking the position, and admin can mark such a position
///         stale once it has been stuck past withdrawalDelay past maturity.
contract StuckActiveRescueTest is BaseTest {
    function _isStale(uint256 idx) internal view returns (bool isStale) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok);
        assembly {
            isStale := mload(add(data, 256))
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   pokeDecentral on stuck Active doesn't revert
    // ═══════════════════════════════════════════════════════════════════════

    function test_pokeDecentral_pausedPool_doesNotRevertOnActive() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61); // past maturity

        // Decentral pauses
        pool.setPaused(true);

        // pokeDecentral must not revert; position stays Active
        vault.pokeDecentral(0);

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "still Active after failed request");
    }

    function test_pokeDecentral_shutdownPool_doesNotRevertOnActive() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        pool.setShutdown(true);

        vault.pokeDecentral(0); // must not revert

        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "still Active after shutdown");
    }

    function test_pokeDecentral_emitsWithdrawalDelayed_afterTwoDelays() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        pool.setPaused(true);

        // Warp past 2 * withdrawalDelay since maturity
        vm.warp(block.timestamp + 2 * FORTY_EIGHT_HOURS + 1);

        vm.recordLogs();
        vault.pokeDecentral(0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expected = keccak256("WithdrawalDelayed(uint256,uint256)");
        bool sawEvent;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == expected) {
                sawEvent = true;
                break;
            }
        }
        assertTrue(sawEvent, "WithdrawalDelayed should fire after 2x delay");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   markPositionStale rescues stuck Active position
    // ═══════════════════════════════════════════════════════════════════════

    function test_markPositionStale_acceptsActivePastMaturityPlusDelay() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        // Decentral pauses; pokeDecentral can't progress the position
        pool.setPaused(true);
        vault.pokeDecentral(0);

        // Wait past maturity + withdrawalDelay
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0); // must succeed

        assertTrue(_isStale(0), "position is stale");
        assertEq(vault.totalInvestedPrincipal(), 0, "principal moved to stale");
        assertGt(vault.totalStaleValue(), TEN_THOUSAND_HOLLAR, "stale > principal (includes accrued yield)");
    }

    function test_markPositionStale_revertsIfActiveBeforeMaturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        // Position is Active but not yet matured
        vm.prank(admin);
        vm.expectRevert(HDCLVault.PositionNotStuckLongEnough.selector);
        vault.markPositionStale(0);
    }

    function test_markPositionStale_revertsIfActiveBeforeDelayPastMaturity() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61); // matured but withdrawalDelay hasn't elapsed since maturity

        vm.prank(admin);
        vm.expectRevert(HDCLVault.PositionNotStuckLongEnough.selector);
        vault.markPositionStale(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   Recovery: unmark Active-staled position resumes accrual
    // ═══════════════════════════════════════════════════════════════════════

    function test_unmarkPositionStale_active_resumesAccrual() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        pool.setPaused(true);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        uint256 rateAtStale = vault.exchangeRate();

        // Unpause Decentral and unmark
        pool.setPaused(false);
        vm.prank(admin);
        vault.unmarkPositionStale(0);

        // Rate is preserved across unmark
        assertApproxEqRel(vault.exchangeRate(), rateAtStale, 0.001e18, "rate preserved");

        // Yield bookkeeping is restored — rate should grow over time
        uint256 r0 = vault.exchangeRate();
        _warpDays(15);
        assertGt(vault.exchangeRate(), r0, "yield resumes accruing after unmark");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   AUDIT FINDING #2 — Decentral recovery after stale-Active mark
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Set up the stale-Active state used by the next three tests:
    ///      alice deposits, position matures, Decentral pauses so pokeDecentral
    ///      can't progress, admin marks stale once stuck past `withdrawalDelay`,
    ///      and then Decentral recovers (unpaused). The position is now
    ///      Active + isStale, with bucket bookkeeping cleared.
    function _setupStaleActiveThenRecover() internal {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        pool.setPaused(true);
        vault.pokeDecentral(0); // no-op while paused
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        pool.setPaused(false); // Decentral recovers

        // Sanity: state stayed Active, bucket aggregates cleared, value parked.
        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "state still Active after stale-mark");
        assertTrue(_isStale(0), "position is stale");
        assertEq(vault.totalInvestedPrincipal(), 0, "principal cleared from bucket");
        assertEq(vault.yieldRateSum(), 0, "yield aggregates cleared");
        assertGt(vault.totalStaleValue(), 0, "value parked in totalStaleValue");
    }

    /// @notice Regression for the audit finding: pre-fix, this `pokeDecentral`
    ///         call would underflow `_removeYieldFromBucket` inside the
    ///         try-block's success body (try/catch does NOT catch reverts
    ///         inside the body) and revert the entire tx — bricking every
    ///         subsequent permissionless poke until admin's `unmarkPositionStale`.
    ///         Post-fix, the call no-ops cleanly with no state mutation.
    function test_pokeDecentral_staleActiveAfterRecovery_doesNotRevert() public {
        _setupStaleActiveThenRecover();

        // Pre-fix: this reverts via _removeYieldFromBucket underflow.
        // Post-fix: returns cleanly.
        vault.pokeDecentral(0);

        // State unchanged: still Active + stale.
        (, , , , , uint8 state) = vault.getPosition(0);
        assertEq(state, 0, "state still Active after skipped poke");
        assertTrue(_isStale(0), "still stale");
    }

    /// @notice The skip emits `PositionPokeSkippedStale` so operators can see
    ///         that a permissionless poke was deferred (vs. a generic catch
    ///         no-op from a paused Decentral). Surfacing this is the only way
    ///         a keeper monitor can tell that admin intervention is required.
    function test_pokeDecentral_staleActive_emitsSkippedEvent() public {
        _setupStaleActiveThenRecover();

        vm.recordLogs();
        vault.pokeDecentral(0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expected = keccak256("PositionPokeSkippedStale(uint256)");
        bool sawEvent;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == expected) {
                sawEvent = true;
                // positionIndex is indexed → topic[1]
                assertEq(
                    uint256(logs[i].topics[1]),
                    0,
                    "event references position 0"
                );
                break;
            }
        }
        assertTrue(sawEvent, "PositionPokeSkippedStale should fire");
    }

    /// @notice The skipped poke must not mutate global accounting — the bug
    ///         would have either (a) reverted (caught above) or (b) succeeded
    ///         in a corrupt way that re-removed from already-zero bucket
    ///         aggregates AND set `pendingYield` while `staleYield` is still
    ///         live (double-counting yield in `totalAssets()`).
    function test_pokeDecentral_staleActive_accountingUnchanged() public {
        _setupStaleActiveThenRecover();

        // Snapshot every piece of state the buggy success body would have
        // touched.
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalStaleBefore = vault.totalStaleValue();
        uint256 totalPendingBefore = vault.totalPendingYield();
        uint256 totalPrincipalBefore = vault.totalInvestedPrincipal();
        uint256 yieldRateSumBefore = vault.yieldRateSum();
        uint256 rateBefore = vault.exchangeRate();

        vault.pokeDecentral(0);

        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged");
        assertEq(vault.totalStaleValue(), totalStaleBefore, "totalStaleValue unchanged");
        assertEq(vault.totalPendingYield(), totalPendingBefore, "totalPendingYield unchanged");
        assertEq(vault.totalInvestedPrincipal(), totalPrincipalBefore, "totalInvestedPrincipal unchanged");
        assertEq(vault.yieldRateSum(), yieldRateSumBefore, "yieldRateSum unchanged");
        assertEq(vault.exchangeRate(), rateBefore, "rate unchanged");
    }

    /// @notice Single-position case exposes the underflow most directly:
    ///         alice's position is the ONLY contributor to the bucket. After
    ///         mark-stale, every aggregate is 0. Pre-fix, the second
    ///         `_removeYieldFromBucket` would subtract a positive value from
    ///         0 → underflow → revert. Post-fix, the guard returns first.
    function test_pokeDecentral_staleActive_singlePosition_noUnderflow() public {
        // Same setup as _setupStaleActiveThenRecover but inlined to make the
        // single-position assumption explicit (no other positions buffer the
        // underflow that would otherwise be data-dependent).
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        pool.setPaused(true);
        vault.pokeDecentral(0);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);

        vm.prank(admin);
        vault.markPositionStale(0);

        // Aggregates are exactly 0 — any subtraction will underflow.
        assertEq(vault.totalInvestedPrincipal(), 0, "principal aggregate cleared");
        assertEq(vault.yieldRateSum(), 0, "yield aggregate cleared");

        pool.setPaused(false);

        // The call below would underflow pre-fix. It must succeed post-fix.
        vault.pokeDecentral(0);
    }

    /// @notice After admin `unmarkPositionStale`, the normal keeper lifecycle
    ///         resumes — pokeDecentral progresses Active → YWR as usual. The
    ///         guard is a *pause*, not a permanent block; unmark is the
    ///         single recovery path.
    function test_pokeDecentral_afterUnmark_resumesLifecycle() public {
        _setupStaleActiveThenRecover();

        // While stale, pokeDecentral skips.
        vault.pokeDecentral(0);
        (, , , , , uint8 stillActive) = vault.getPosition(0);
        assertEq(stillActive, 0, "still Active while stale");

        // Admin unmarks — bucket bookkeeping restored.
        vm.prank(admin);
        vault.unmarkPositionStale(0);
        assertFalse(_isStale(0), "no longer stale");
        assertGt(vault.totalInvestedPrincipal(), 0, "principal restored to bucket");

        // Keeper poke now progresses past Active.
        vault.pokeDecentral(0);
        (, , , , , uint8 advancedState) = vault.getPosition(0);
        assertEq(advancedState, 1, "advanced to YieldWithdrawalRequested");
    }
}
