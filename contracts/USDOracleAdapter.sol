// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import "@aave/periphery-v3/contracts/misc/interfaces/IEACAggregatorProxy.sol";
import {AggregatorInterface} from '@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol';

contract  USDOracleAdapter is IEACAggregatorProxy {

    uint8 public constant decimals = 8;

    AggregatorInterface public assetToXOracle;
    AggregatorInterface public XToUsdOracle;

    constructor(address _assetToXOracle, address _XToUsdOracle) {
        assetToXOracle = AggregatorInterface(_assetToXOracle);
        XToUsdOracle = AggregatorInterface(_XToUsdOracle);
    }

    function latestAnswer() external view returns (int256) {
        return int256((uint256(assetToXOracle.latestAnswer()) * uint256(XToUsdOracle.latestAnswer())) / uint256(10) ** decimals);
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
