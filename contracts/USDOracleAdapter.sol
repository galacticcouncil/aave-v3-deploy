// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {AggregatorInterface} from '@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol';

contract  USDOracleAdapter {
    AggregatorInterface _assetToXOracle;
    AggregatorInterface _XToUsdOracle;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 timestamp);
    event NewRound(uint256 indexed roundId, address indexed startedBy);

    error NotImplemented();

    constructor(address assetToXOracle, address XToUsdOracle) {
        _assetToXOracle = AggregatorInterface(assetToXOracle);
        _XToUsdOracle = AggregatorInterface(XToUsdOracle);
    }

    function decimals() external view returns (uint8) {
        return 8;
    }

    function latestAnswer() external view returns (int256) {
        return int256((uint256(_assetToXOracle.latestAnswer()) * uint256(_XToUsdOracle.latestAnswer())) /uint256(10)**8);
    }

    function latestTimestamp() external view returns (uint256) {
        revert NotImplemented();
    }

    function latestRound() external view returns (uint256) {
        revert NotImplemented();
    }

    function getAnswer(uint256 roundId) external view returns (int256) {
        return int256((uint256(_assetToXOracle.latestAnswer()) * uint256(_XToUsdOracle.latestAnswer())) /uint256(10)**8);
    }

    function getTimestamp(uint256 roundId) external view returns (uint256) {
        revert NotImplemented();
    } 
}
