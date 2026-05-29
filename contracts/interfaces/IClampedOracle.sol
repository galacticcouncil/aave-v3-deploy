// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IClampedOracle {
    error InvalidFeed();
    error InvalidBps();
    error NoValidPrice();

    event ClampedOracleInitialized(
        address indexed primaryFeed,
        address indexed secondaryFeed,
        uint256 maxDiffBps
    );

    function maxDiffBps() external view returns (uint256);

    function primary() external view returns (address);

    function secondary() external view returns (address);

    function decimals() external view returns (uint8);

    function latestAnswer() external view returns (int256);

    function latestTimestamp() external view returns (uint256);

    function latestRound() external view returns (uint256);

    function getAnswer(uint256 roundId) external view returns (int256);

    function getTimestamp(uint256 roundId) external view returns (uint256);
}
