// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {BILOracle} from "../../src/BILOracle.sol";

/// @dev Minimal vault stub that lets us drive the oracle with arbitrary rates.
contract MockRateVault {
    uint256 public exchangeRate;
    function setRate(uint256 r) external {
        exchangeRate = r;
    }
}

/// @title BILOracle Zero-Answer Defense
/// @notice Verifies the oracle reverts rather than returning a zero answer
///         when the vault's exchange rate would truncate to zero (rate < 1e10).
///         A zero price downstream can trigger mass liquidations in lending
///         markets — reverting forces consumers to handle the failure mode.
contract OracleZeroCheckTest is Test {
    MockRateVault internal vault;
    BILOracle internal oracle;

    function setUp() public {
        vault = new MockRateVault();
        oracle = new BILOracle(address(vault));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ZERO-RATE: revert
    // ═══════════════════════════════════════════════════════════════════════

    function test_latestRoundData_revertsOnZeroRate() public {
        vault.setRate(0);
        vm.expectRevert("BILOracle: rate truncates to zero");
        oracle.latestRoundData();
    }

    function test_getRoundData_revertsOnZeroRate() public {
        vault.setRate(0);
        vm.expectRevert("BILOracle: rate truncates to zero");
        oracle.getRoundData(0);
    }

    /// @notice rate < 1e10 truncates to zero in `int256(rate / 1e10)` — must revert.
    function test_revertsWhenRateTruncatesToZero() public {
        vault.setRate(1e10 - 1); // 9_999_999_999 → /1e10 = 0
        vm.expectRevert("BILOracle: rate truncates to zero");
        oracle.latestRoundData();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   BOUNDARY: exactly 1e10 returns 1 (smallest positive answer)
    // ═══════════════════════════════════════════════════════════════════════

    function test_minimumPositiveRateReturnsOne() public {
        vault.setRate(1e10);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 1, "rate=1e10 -> answer=1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   NORMAL OPERATION: 1:1 rate → answer = 1e8
    // ═══════════════════════════════════════════════════════════════════════

    function test_normalRateProducesValidAnswer() public {
        vault.setRate(1e18); // 1:1
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 1e8, "rate=1e18 -> answer=1e8 (8 decimal Chainlink form)");
    }

    function test_normalRateGetRoundDataMatches() public {
        vault.setRate(1.23e18);
        (, int256 latest,,,) = oracle.latestRoundData();
        (, int256 round,,,) = oracle.getRoundData(42);
        assertEq(latest, round, "getRoundData matches latestRoundData");
        assertEq(latest, 1.23e8, "rate scaled to 8 decimals");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FUZZ: revert iff rate < 1e10
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_revertOrSucceed(uint256 rate) public {
        rate = bound(rate, 0, type(uint128).max);
        vault.setRate(rate);

        if (rate < 1e10) {
            vm.expectRevert("BILOracle: rate truncates to zero");
            oracle.latestRoundData();
        } else {
            (, int256 answer,,,) = oracle.latestRoundData();
            assertGt(answer, 0, "fuzz: answer > 0 when rate >= 1e10");
            assertEq(uint256(answer), rate / 1e10, "fuzz: scaling correct");
        }
    }
}
