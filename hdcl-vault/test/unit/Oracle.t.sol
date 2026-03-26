// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {WDCLOracle} from "../../src/WDCLOracle.sol";

contract OracleTest is BaseTest {
    WDCLOracle public oracle;

    function setUp() public override {
        super.setUp();
        // Deploy oracle pointing at the vault
        oracle = new WDCLOracle(address(vault));
        // Seed the vault with a deposit so totalSupply > 0 and exchange rate is meaningful
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    // ─── latestRoundData ─────────────────────────────────────────────────

    function test_latestRoundData_answerMatchesExchangeRate() public view {
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 rate = vault.exchangeRate();
        // Oracle returns rate / 1e10 (8 decimals)
        assertEq(uint256(answer), rate / 1e10, "answer should equal exchangeRate / 1e10");
    }

    function test_latestRoundData_updatedAtMatchesBlockTimestamp() public {
        vm.warp(1_700_000_000);
        (,, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp, "updatedAt should equal block.timestamp");
        assertEq(startedAt, block.timestamp, "startedAt should equal block.timestamp");
    }

    function test_latestRoundData_roundIdMatchesBlockNumber() public {
        vm.roll(42);
        (uint80 roundId,,,, uint80 answeredInRound) = oracle.latestRoundData();
        assertEq(uint256(roundId), block.number, "roundId should equal block.number");
        assertEq(uint256(answeredInRound), block.number, "answeredInRound should equal block.number");
    }

    // ─── getRoundData ────────────────────────────────────────────────────

    function test_getRoundData_returnsSameAsLatestRoundData() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.getRoundData(999);

        (uint80 latestRoundId, int256 latestAnswer, uint256 latestStartedAt, uint256 latestUpdatedAt, uint80 latestAnsweredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, latestRoundId, "roundId should match");
        assertEq(answer, latestAnswer, "answer should match");
        assertEq(startedAt, latestStartedAt, "startedAt should match");
        assertEq(updatedAt, latestUpdatedAt, "updatedAt should match");
        assertEq(answeredInRound, latestAnsweredInRound, "answeredInRound should match");
    }

    // ─── Oracle metadata ────────────────────────────────────────────────

    function test_oracleDecimals() public view {
        assertEq(oracle.decimals(), 8, "oracle decimals should be 8");
    }

    function test_oracleDescription() public view {
        assertEq(oracle.description(), "wDCL / HOLLAR", "oracle description should be 'wDCL / HOLLAR'");
    }

    function test_oracleVersion() public view {
        assertEq(oracle.version(), 1, "oracle version should be 1");
    }

    // ─── Exchange rate appreciation reflects in oracle ────────────────────

    function test_latestRoundData_rateAppreciatesWithTime() public {
        (, int256 answerBefore,,,) = oracle.latestRoundData();

        _warpDays(30);

        (, int256 answerAfter,,,) = oracle.latestRoundData();
        assertGt(uint256(answerAfter), uint256(answerBefore), "exchange rate should increase after time passes");
    }

    // ─── Reverts when vault is paused ────────────────────────────────────

    function test_latestRoundData_revertsWhenPaused() public {
        vm.prank(admin);
        vault.pause();

        vm.expectRevert("Vault paused");
        oracle.latestRoundData();
    }
}
