// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {AggregatorV3Interface} from "./dependencies/chainlink/AggregatorV3Interface.sol";

contract HybridOracleAggregator is AggregatorV3Interface, AggregatorInterface {

    uint8 public constant decimals = 8;

    AggregatorV3Interface public srcAssetToXOracle;
    AggregatorInterface public destAssetToXOracle;

    constructor(address _srcAssetToXOracle, address _destAssetToXOracle) {
        srcAssetToXOracle = AggregatorV3Interface(_srcAssetToXOracle);
        destAssetToXOracle = AggregatorInterface(_destAssetToXOracle);
    }

    function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        (uint80 rountId, int256 srcToX, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = srcAssetToXOracle.latestRoundData();
        int256 xToDest = destAssetToXOracle.latestAnswer();

        answer = int256((uint256(srcToX) * uint256(xToDest)) / uint256(10) ** decimals);

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function description() external view returns (string memory) {
        return "";
    }

    function version() external view returns (uint256) {
        return 0;
    }

    function getRoundData(
        uint80 _roundId
    ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        return this.latestRoundData();
    }

    function latestAnswer() external view returns (int256) {
        (, int256 answer, , , ) = this.latestRoundData();
        return answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external view returns (uint256) {
        return 0;
    }

    function getAnswer(uint256 roundId) external view returns (int256) {
        return this.latestAnswer();
    }

    function getTimestamp(uint256 roundId) external view returns (uint256) {
        return 0;
    }
}
