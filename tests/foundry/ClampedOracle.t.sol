// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ClampedOracle} from "../../../contracts/ClampedOracle.sol";
import {IClampedOracle} from "../../../contracts/interfaces/IClampedOracle.sol";

import {MockAggregator} from "./mocks/MockAggregator.sol";
import {RevertingAggregator} from "./mocks/RevertingAggregator.sol";
import {MockHydraChainlinkOracle} from "./mocks/MockHydraChainlinkOracle.sol";
import {RevertingHydraChainlinkOracle} from "./mocks/RevertingHydraChainlinkOracle.sol";

contract ClampedOracleTest is Test {
    MockAggregator primary;
    MockHydraChainlinkOracle secondary;

    function setUp() public {
        primary = new MockAggregator();
        secondary = new MockHydraChainlinkOracle();
    }

    /// @dev Build an 8-decimal price from `whole` and `frac2Digits` (hundredths).
    /// p(1, 50) == 1.50e8, p(0, 80) == 0.80e8.
    function p(
        uint256 whole,
        uint256 frac2Digits
    ) internal pure returns (int256) {
        return int256(whole * 1e8 + (frac2Digits * 1e6));
    }

    function _deploy(uint256 maxDiffBps) internal returns (ClampedOracle) {
        return
            new ClampedOracle(
                address(primary),
                address(secondary),
                maxDiffBps
            );
    }

    // ---------------------------------------------------------------------
    // latestAnswer: in-band -> returns primary as-is
    // ---------------------------------------------------------------------

    function testInBandReturnsPrimary() public {
        primary.pushAnswer(p(1, 5), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestAnswer(), p(1, 5));
    }

    function testExactPriceMatchReturnsPrimary() public {
        primary.pushAnswer(p(2, 0), 100);
        secondary.pushAnswer(p(2, 0));
        ClampedOracle oracle = _deploy(500);
        assertEq(oracle.latestAnswer(), p(2, 0));
    }

    function testExactlyAtUpperBandReturnsPrimary() public {
        // band = [0.9, 1.1]; primary = 1.10 sits exactly on the upper edge.
        primary.pushAnswer(p(1, 10), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestAnswer(), p(1, 10));
    }

    function testExactlyAtLowerBandReturnsPrimary() public {
        primary.pushAnswer(p(0, 90), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestAnswer(), p(0, 90));
    }

    // ---------------------------------------------------------------------
    // latestAnswer: out of band -> clamps to band edge
    // ---------------------------------------------------------------------

    function testAboveBandClampsToUpper() public {
        // band = [0.9, 1.1]; primary at 1.50 gets clamped down to 1.10.
        primary.pushAnswer(p(1, 50), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestAnswer(), p(1, 10));
    }

    function testBelowBandClampsToLower() public {
        // band = [0.9, 1.1]; primary at 0.80 gets clamped up to 0.90.
        primary.pushAnswer(p(0, 80), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestAnswer(), p(0, 90));
    }

    function testPrimaryManipulationCappedAtMaxDiffBps() public {
        // Primary "manipulated" to 10x. Result is clamped to upper band,
        // capping the manipulator's damage at maxDiffBps from secondary.
        primary.pushAnswer(p(10, 0), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(500); // 5%
        assertEq(oracle.latestAnswer(), p(1, 5));
    }

    function testZeroToleranceClampsPrimaryToSecondary() public {
        // With tolerance 0 the band collapses; primary is forced to secondary.
        primary.pushAnswer(p(1, 23), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(0);
        assertEq(oracle.latestAnswer(), p(1, 0));
    }

    function testMaxToleranceAllowsDoubleAndZero() public {
        // 100% tolerance: band = [0, 2S]. Primary anywhere inside passes.
        primary.pushAnswer(p(2, 0), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(10_000);
        assertEq(oracle.latestAnswer(), p(2, 0));
    }

    function testMaxToleranceClampsBeyondDouble() public {
        // Even at 100% tolerance, secondary still caps primary at 2S.
        primary.pushAnswer(p(5, 0), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(10_000);
        assertEq(oracle.latestAnswer(), p(2, 0));
    }

    // ---------------------------------------------------------------------
    // latestAnswer: secondary unavailable -> primary returned unclamped
    // (liveness preserved at the cost of the sanity bound)
    // ---------------------------------------------------------------------

    function testSecondaryRevertsReturnsPrimaryUnclamped() public {
        RevertingHydraChainlinkOracle revertingSecondary = new RevertingHydraChainlinkOracle();
        primary.pushAnswer(p(1, 23), 100);
        ClampedOracle oracle = new ClampedOracle(
            address(primary),
            address(revertingSecondary),
            1000
        );
        assertEq(oracle.latestAnswer(), p(1, 23));
    }

    function testSecondaryZeroAnswerReturnsPrimaryUnclamped() public {
        primary.pushAnswer(p(1, 23), 100);
        secondary.pushAnswer(int256(0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestAnswer(), p(1, 23));
    }

    // ---------------------------------------------------------------------
    // latestAnswer: primary unavailable -> always reverts
    // ---------------------------------------------------------------------

    function testPrimaryRevertsRevertsNoValidPrice() public {
        RevertingAggregator revertingPrimary = new RevertingAggregator();
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = new ClampedOracle(
            address(revertingPrimary),
            address(secondary),
            1000
        );
        vm.expectRevert(IClampedOracle.NoValidPrice.selector);
        oracle.latestAnswer();
    }

    function testPrimaryZeroAnswerRevertsNoValidPrice() public {
        primary.pushAnswer(int256(0), 100);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        vm.expectRevert(IClampedOracle.NoValidPrice.selector);
        oracle.latestAnswer();
    }

    function testBothFailRevertsNoValidPrice() public {
        RevertingAggregator revertingPrimary = new RevertingAggregator();
        RevertingHydraChainlinkOracle revertingSecondary = new RevertingHydraChainlinkOracle();
        ClampedOracle oracle = new ClampedOracle(
            address(revertingPrimary),
            address(revertingSecondary),
            1000
        );
        vm.expectRevert(IClampedOracle.NoValidPrice.selector);
        oracle.latestAnswer();
    }

    // ---------------------------------------------------------------------
    // latestTimestamp / latestRound: pure passthrough to primary
    // ---------------------------------------------------------------------

    function testLatestTimestampDelegatesPrimary() public {
        primary.pushAnswer(p(1, 0), 777);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestTimestamp(), 777);
    }

    function testLatestTimestampPrimaryRevertsBubbles() public {
        RevertingAggregator revertingPrimary = new RevertingAggregator();
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = new ClampedOracle(
            address(revertingPrimary),
            address(secondary),
            1000
        );
        vm.expectRevert();
        oracle.latestTimestamp();
    }

    function testLatestRoundDelegatesPrimary() public {
        primary.pushAnswer(p(1, 0), 100);
        uint256 r2 = primary.pushAnswer(p(1, 0), 101);
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.latestRound(), r2);
    }

    function testLatestRoundPrimaryRevertsBubbles() public {
        RevertingAggregator revertingPrimary = new RevertingAggregator();
        secondary.pushAnswer(p(1, 0));
        ClampedOracle oracle = new ClampedOracle(
            address(revertingPrimary),
            address(secondary),
            1000
        );
        vm.expectRevert();
        oracle.latestRound();
    }

    // ---------------------------------------------------------------------
    // getAnswer / getTimestamp: same semantic as latestAnswer / latestTimestamp
    // ---------------------------------------------------------------------

    function testGetAnswerInBandReturnsPrimary() public {
        primary.setRoundData(10, p(1, 5), 111);
        secondary.setRoundData(10, p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.getAnswer(10), p(1, 5));
    }

    function testGetAnswerAboveBandClampsToUpper() public {
        primary.setRoundData(10, p(1, 50), 111);
        secondary.setRoundData(10, p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.getAnswer(10), p(1, 10));
    }

    function testGetAnswerSecondaryRevertsReturnsPrimary() public {
        RevertingHydraChainlinkOracle revertingSecondary = new RevertingHydraChainlinkOracle();
        primary.setRoundData(10, p(1, 23), 111);
        ClampedOracle oracle = new ClampedOracle(
            address(primary),
            address(revertingSecondary),
            1000
        );
        assertEq(oracle.getAnswer(10), p(1, 23));
    }

    function testGetAnswerPrimaryRevertsRevertsNoValidPrice() public {
        RevertingAggregator revertingPrimary = new RevertingAggregator();
        secondary.setRoundData(10, p(1, 0));
        ClampedOracle oracle = new ClampedOracle(
            address(revertingPrimary),
            address(secondary),
            1000
        );
        vm.expectRevert(IClampedOracle.NoValidPrice.selector);
        oracle.getAnswer(10);
    }

    function testGetTimestampDelegatesPrimary() public {
        primary.setRoundData(10, p(1, 0), 555);
        secondary.setRoundData(10, p(1, 0));
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.getTimestamp(10), 555);
    }

    function testGetTimestampPrimaryRevertsBubbles() public {
        RevertingAggregator revertingPrimary = new RevertingAggregator();
        secondary.setRoundData(10, p(1, 0));
        ClampedOracle oracle = new ClampedOracle(
            address(revertingPrimary),
            address(secondary),
            1000
        );
        vm.expectRevert();
        oracle.getTimestamp(10);
    }

    // ---------------------------------------------------------------------
    // constructor
    // ---------------------------------------------------------------------

    function testConstructorZeroPrimaryReverts() public {
        vm.expectRevert(IClampedOracle.InvalidFeed.selector);
        new ClampedOracle(address(0), address(secondary), 1000);
    }

    function testConstructorZeroSecondaryReverts() public {
        vm.expectRevert(IClampedOracle.InvalidFeed.selector);
        new ClampedOracle(address(primary), address(0), 1000);
    }

    function testConstructorInvalidBpsReverts() public {
        vm.expectRevert(IClampedOracle.InvalidBps.selector);
        new ClampedOracle(address(primary), address(secondary), 10_001);
    }

    function testConstructorEmitsInitialized() public {
        vm.expectEmit(true, true, false, true);
        emit IClampedOracle.ClampedOracleInitialized(
            address(primary),
            address(secondary),
            1000
        );
        new ClampedOracle(address(primary), address(secondary), 1000);
    }

    // ---------------------------------------------------------------------
    // misc
    // ---------------------------------------------------------------------

    function testDecimalsIsEight() public {
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.decimals(), 8);
    }

    function testPrimaryAndSecondaryGetters() public {
        ClampedOracle oracle = _deploy(1000);
        assertEq(oracle.primary(), address(primary));
        assertEq(oracle.secondary(), address(secondary));
        assertEq(oracle.maxDiffBps(), 1000);
    }
}
