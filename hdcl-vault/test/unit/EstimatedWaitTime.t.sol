// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title getEstimatedWaitTime — View Liveness Under Stale Edge Cases
/// @notice Regression coverage for the underflow that would brick the view
///         when an Active-stale position is unmarked long enough after
///         marking that the back-calculated `yieldStartTime` drifts past the
///         immutable `maturityTime`.
contract EstimatedWaitTimeTest is BaseTest {
    function _readYieldStartTime(uint256 idx) internal view returns (uint256 yst) {
        // NFTPosition layout offsets (see HDCLVault struct):
        //   slot 0: tokenId, 1: principal, 2: apyWad, 3: depositTime,
        //   slot 4: maturityTime, 5: yieldStartTime, ...
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok);
        assembly { yst := mload(add(data, 192)) }
    }

    function _readMaturityTime(uint256 idx) internal view returns (uint256 m) {
        (bool ok, bytes memory data) = address(vault).staticcall(
            abi.encodeWithSignature("positions(uint256)", idx)
        );
        require(ok);
        assembly { m := mload(add(data, 160)) }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   NORMAL: yieldStartTime ≤ maturityTime — view returns sensibly
    // ═══════════════════════════════════════════════════════════════════════

    function test_getEstimatedWaitTime_normalPosition_returnsValue() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Bob queues a redemption. Idle HOLLAR is 0, so the walk goes through
        // alice's still-Active position 0.
        _deposit(bob, 1_000e18);
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 reqId = vault.requestRedeem(bobHdcl);

        // View must not revert and should return a non-zero ETA (position 0
        // is still pre-maturity).
        uint256 eta = vault.getEstimatedWaitTime(reqId);
        assertGt(eta, 0, "ETA should be positive for pre-maturity coverage");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   AUDIT FINDING #4 REGRESSION — long-stale unmark must not brick view
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Construct the pathological state: position is Active, has been
    ///      marked stale long after maturity, then unmarked after enough
    ///      additional time that the back-calculated yieldStartTime exceeds
    ///      the original maturityTime.
    function _setupLongStaleUnmark() internal {
        // T=0: alice deposits 10K. depositTime=0, maturityTime=60d.
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // T=63d: past maturity + 48h delay; pool is paused so pokeDecentral
        // can't progress the position.
        _warpDays(63);
        pool.setPaused(true);
        vault.pokeDecentral(0); // no-op while paused

        // Mark stale. At this point staleYield captures yield from
        // T=0..T=63d (63 days of accrual).
        vm.prank(admin);
        vault.markPositionStale(0);

        // Position sits stale for a LONG time (200 more days). Total
        // elapsed since mark = 200d; total elapsed since deposit = 263d.
        _warpDays(200);

        // Pool recovers, admin unmarks. Active branch back-calculates
        // yieldStartTime = block.timestamp − elapsed, where elapsed ≈ 63d
        // (the duration baked into staleYield). So yieldStartTime ≈
        // (63+200)d − 63d = 200d ≫ maturityTime = 60d.
        pool.setPaused(false);
        vm.prank(admin);
        vault.unmarkPositionStale(0);
    }

    /// @notice Pre-fix this call would underflow on `maturityTime − yieldStartTime`
    ///         inside the for-loop and revert. Post-fix it clamps to 0 and
    ///         returns a sensible (conservative) ETA.
    function test_getEstimatedWaitTime_longStaleUnmark_doesNotRevert() public {
        _setupLongStaleUnmark();

        // Sanity: the pathological state exists.
        uint256 yst = _readYieldStartTime(0);
        uint256 mat = _readMaturityTime(0);
        assertGt(yst, mat, "yieldStartTime drifted past maturityTime");

        // Bob queues a redemption. Idle HOLLAR is 0 → walk reaches position 0.
        _deposit(bob, 1_000e18);
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 reqId = vault.requestRedeem(bobHdcl);

        // Pre-fix: reverts on uint256 underflow. Post-fix: returns cleanly.
        uint256 eta = vault.getEstimatedWaitTime(reqId);

        // The position is already past maturity, so `maturityWithDelay` is in
        // the past → ETA == 0 (next pokeDecentral lifecycle can finish
        // immediately, plus Decentral's 48h delay which has also already
        // elapsed).
        assertEq(eta, 0, "past-maturity position: no wait projected");
    }

    /// @notice The clamp must not change behavior for the normal case where
    ///         yieldStartTime ≤ maturityTime — confirm a fresh position
    ///         produces the same wait estimate as before the fix.
    function test_getEstimatedWaitTime_freshPosition_unchanged() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        _deposit(bob, 1_000e18);
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 reqId = vault.requestRedeem(bobHdcl);

        // For a freshly-deposited position, yieldStartTime == depositTime <
        // maturityTime. The ternary picks the original arithmetic branch.
        uint256 yst = _readYieldStartTime(0);
        uint256 mat = _readMaturityTime(0);
        assertLt(yst, mat, "fresh position: yieldStartTime < maturityTime");

        uint256 eta = vault.getEstimatedWaitTime(reqId);
        // Position 0 covers bob's small redemption easily; ETA = time until
        // position 0 matures + Decentral's 48h delay. Just assert it's
        // non-zero and bounded.
        assertGt(eta, 0, "ETA should reflect time-to-maturity");
        assertLt(eta, 100 days, "ETA should be reasonable");
    }
}
