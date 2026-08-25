// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IAggregatorV3Interface
/// @notice Standard Chainlink V3 price feed aggregator interface.
/// @dev Used by the vault to fetch stablecoin price data for exchange rate calculations.
interface IAggregatorV3Interface {
    /// @notice Returns the number of decimals in the price feed's answer.
    /// @return The number of decimals (e.g., 8 for USD price feeds).
    function decimals() external view returns (uint8);

    /// @notice Returns a human-readable description of the price feed.
    /// @return A string describing the price pair (e.g., "USDC / USD").
    function description() external view returns (string memory);

    /// @notice Returns the version number of the aggregator.
    /// @return The aggregator version.
    function version() external view returns (uint256);

    /// @notice Returns price data for a specific round.
    /// @param _roundId The round ID to retrieve data for.
    /// @return roundId The round ID.
    /// @return answer The price answer for this round.
    /// @return startedAt The timestamp when the round started.
    /// @return updatedAt The timestamp when the round was last updated.
    /// @return answeredInRound The round ID in which the answer was computed.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Returns the latest price data from the feed.
    /// @return roundId The most recent round ID.
    /// @return answer The latest price answer.
    /// @return startedAt The timestamp when the latest round started.
    /// @return updatedAt The timestamp when the latest round was last updated.
    /// @return answeredInRound The round ID in which the latest answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
