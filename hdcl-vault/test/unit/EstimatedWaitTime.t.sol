// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

/// @title getEstimatedWaitTime — View Liveness
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
        uint256 reqId = vault.requestRedeem(bobHdcl, bob, bob);

        // View must not revert and should return a non-zero ETA (position 0
        // is still pre-maturity).
        uint256 eta = vault.getEstimatedWaitTime(reqId);
        assertGt(eta, 0, "ETA should be positive for pre-maturity coverage");
    }

    /// @notice Confirm a fresh position produces a sensible wait estimate.
    function test_getEstimatedWaitTime_freshPosition_unchanged() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        _deposit(bob, 1_000e18);
        uint256 bobHdcl = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 reqId = vault.requestRedeem(bobHdcl, bob, bob);

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
