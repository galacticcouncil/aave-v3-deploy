// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {AggregatorInterface} from '@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol';

contract  USDOracleAdapter {
    AggregatorInterface _assetToXOracle;
    AggregatorInterface _XToUsdOracle;
    uint8 _decimals;

    error NotImplemented();

    constructor(address assetToXOracle, address XToUsdOracle, uint8 decimals) {
        _assetToXOracle = AggregatorInterface(assetToXOracle);
        _XToUsdOracle = AggregatorInterface(XToUsdOracle);
        _decimals = decimals;
    }
    function latestAnswer() external view returns (int256) {
        return int256((uint256(_assetToXOracle.getAnswer(0)) * uint256(_XToUsdOracle.latestAnswer())) /uint256(_decimals));
    }

    function latestTimestamp() external view returns (uint256) {
        revert NotImplemented();
    }

    function latestRound() external view returns (uint256) {
        revert NotImplemented();
    }

    function getAnswer(uint256 roundId) external view returns (int256) {
        return int256((uint256(_assetToXOracle.getAnswer(0)) * uint256(_XToUsdOracle.latestAnswer())) /uint256(_decimals));
    }

    function getTimestamp(uint256 roundId) external view returns (uint256) {
        revert NotImplemented();
    } 
}
