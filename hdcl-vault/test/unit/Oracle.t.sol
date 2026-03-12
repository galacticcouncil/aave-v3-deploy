// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";

contract OracleTest is BaseTest {
    function setUp() public override {
        super.setUp();
        // Seed the vault with a deposit so totalSupply > 0 and exchange rate is meaningful
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    // ─── latestRoundData ─────────────────────────────────────────────────

    function test_latestRoundData_answerMatchesExchangeRate() public view {
        (, int256 answer,,,) = vault.latestRoundData();
        uint256 rate = vault.exchangeRate();
        assertEq(uint256(answer), rate, "answer should equal exchangeRate()");
    }

    function test_latestRoundData_updatedAtMatchesBlockTimestamp() public {
        // Warp to a known timestamp so we can check
        vm.warp(1_700_000_000);
        (,, uint256 startedAt, uint256 updatedAt,) = vault.latestRoundData();
        assertEq(updatedAt, block.timestamp, "updatedAt should equal block.timestamp");
        assertEq(startedAt, block.timestamp, "startedAt should equal block.timestamp");
    }

    function test_latestRoundData_roundIdMatchesBlockNumber() public {
        // Roll to a known block so we can check
        vm.roll(42);
        (uint80 roundId,,,, uint80 answeredInRound) = vault.latestRoundData();
        assertEq(uint256(roundId), block.number, "roundId should equal block.number");
        assertEq(uint256(answeredInRound), block.number, "answeredInRound should equal block.number");
    }

    // ─── getRoundData ────────────────────────────────────────────────────

    function test_getRoundData_returnsSameAsLatestRoundData() public view {
        // getRoundData ignores the roundId parameter and returns current state
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            vault.getRoundData(999);

        (uint80 latestRoundId, int256 latestAnswer, uint256 latestStartedAt, uint256 latestUpdatedAt, uint80 latestAnsweredInRound) =
            vault.latestRoundData();

        assertEq(roundId, latestRoundId, "roundId should match");
        assertEq(answer, latestAnswer, "answer should match");
        assertEq(startedAt, latestStartedAt, "startedAt should match");
        assertEq(updatedAt, latestUpdatedAt, "updatedAt should match");
        assertEq(answeredInRound, latestAnsweredInRound, "answeredInRound should match");
    }

    // ─── oracleDescription & oracleVersion ───────────────────────────────

    function test_oracleDescription_returnsCorrectString() public view {
        string memory desc = vault.oracleDescription();
        assertEq(desc, "HDCL / HOLLAR", "oracle description should be 'HDCL / HOLLAR'");
    }

    function test_oracleVersion_returnsOne() public view {
        uint256 v = vault.oracleVersion();
        assertEq(v, 1, "oracle version should be 1");
    }

    // ─── Exchange rate appreciation reflects in oracle ────────────────────

    function test_latestRoundData_rateAppreciatesWithTime() public {
        (, int256 answerBefore,,,) = vault.latestRoundData();

        // Warp forward 30 days so yield accrues
        _warpDays(30);

        (, int256 answerAfter,,,) = vault.latestRoundData();
        assertGt(uint256(answerAfter), uint256(answerBefore), "exchange rate should increase after time passes");
    }
}
