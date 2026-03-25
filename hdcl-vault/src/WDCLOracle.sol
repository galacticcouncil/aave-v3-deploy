// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAggregatorV3Interface} from "./interfaces/IAggregatorV3Interface.sol";

interface IHDCLVault {
    function exchangeRate() external view returns (uint256);
    function paused() external view returns (bool);
}

/// @title WDCLOracle
/// @notice Chainlink-compatible oracle for wDCL/HOLLAR exchange rate.
/// @dev This is a purely on-chain oracle — it reads the vault's live exchange rate.
///      `updatedAt` is always `block.timestamp` because the rate is computed on every call.
///      Downstream consumers should NOT rely on round-based staleness checks — this oracle
///      has no heartbeat failure mode. It reverts when the vault is paused.
contract WDCLOracle is IAggregatorV3Interface {
    IHDCLVault public immutable vault;

    constructor(address _vault) {
        require(_vault != address(0), "Zero vault");
        vault = IHDCLVault(_vault);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "wDCL / HOLLAR";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        require(!vault.paused(), "Vault paused");
        uint256 rate = vault.exchangeRate();
        return (
            uint80(block.number),
            int256(rate / 1e10),
            block.timestamp,
            block.timestamp,
            uint80(block.number)
        );
    }

    function getRoundData(
        uint80
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        require(!vault.paused(), "Vault paused");
        uint256 rate = vault.exchangeRate();
        return (
            uint80(block.number),
            int256(rate / 1e10),
            block.timestamp,
            block.timestamp,
            uint80(block.number)
        );
    }
}
