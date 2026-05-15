// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {WDCLOracle} from "../../src/WDCLOracle.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

    // ─── Works while vault is paused ─────────────────────────────────────

    /// @notice Pause is a vault-level emergency state, but the oracle keeps serving
    ///         the rate so downstream lending markets don't break (no liquidation
    ///         lockup or unprice-able collateral while the vault is paused).
    function test_latestRoundData_worksWhenPaused() public {
        vm.prank(admin);
        vault.pause();

        // Should NOT revert; should return the current rate.
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(uint256(answer), vault.exchangeRate() / 1e10, "answer = rate / 1e10");
        assertEq(updatedAt, block.timestamp, "updatedAt = current timestamp");
    }

    // ─── Constructor ───────────────────────────────────────────────────────

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert("Zero vault");
        new WDCLOracle(address(0));
    }

    // ─── Zero supply (no deposits) ────────────────────────────────────────

    function test_latestRoundData_zeroSupply_returnsOneToOne() public {
        // Deploy a brand new vault with no deposits
        HDCLVault impl = new HDCLVault();
        bytes memory initData = abi.encodeCall(
            HDCLVault.initialize,
            (address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        HDCLVault emptyVault = HDCLVault(address(proxy));

        WDCLOracle emptyOracle = new WDCLOracle(address(emptyVault));

        (, int256 answer,,,) = emptyOracle.latestRoundData();
        // rate = 1e18 when supply=0, answer = 1e18 / 1e10 = 1e8
        assertEq(uint256(answer), 1e8, "Zero supply: answer should be 1e8 (1:1 rate)");
        assertGt(answer, 0, "Answer always positive");
    }

    // ─── getRoundData works while paused ─────────────────────────────────

    function test_getRoundData_worksWhenPaused() public {
        vm.prank(admin);
        vault.pause();

        (, int256 answer,,,) = oracle.getRoundData(0);
        assertEq(uint256(answer), vault.exchangeRate() / 1e10, "getRoundData should serve current rate while paused");
    }
}
