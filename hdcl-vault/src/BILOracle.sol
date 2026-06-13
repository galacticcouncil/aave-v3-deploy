// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAggregatorV3Interface} from "./interfaces/IAggregatorV3Interface.sol";

interface IBILVault {
    function exchangeRate() external view returns (uint256);
}

/// @title BILOracle
/// @notice Chainlink-compatible oracle for BIL/HOLLAR exchange rate.
/// @dev This is a purely on-chain oracle — it reads the vault's live exchange rate.
///      `updatedAt` is always `block.timestamp` because the rate is computed on every call.
///      Downstream consumers should NOT rely on round-based staleness checks — this oracle
///      has no heartbeat failure mode.
///
///      The oracle does NOT revert when the vault is paused. Pause is a vault-level
///      emergency state that stops state-changing operations, but the underlying
///      accounting (totalAssets / totalSupply) remains readable and meaningful, so the
///      exchange rate computation is still correct. Reverting here would cascade into
///      downstream lending markets — blocking liquidations and borrow/withdraw flows
///      against BIL collateral, potentially causing bad debt while the vault is paused.
///      To signal "do not trust this feed" to integrators, prefer setting the vault's
///      oracle pointer to a sentinel address or rotating to a replacement oracle.
contract BILOracle is IAggregatorV3Interface {
    IBILVault public immutable vault;

    constructor(address _vault) {
        require(_vault != address(0), "Zero vault");
        vault = IBILVault(_vault);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "BIL / HOLLAR";
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
        answer = _scaledAnswer();
        return (
            uint80(block.number),
            answer,
            block.timestamp,
            block.timestamp,
            uint80(block.number)
        );
    }

    /// @notice Permissive Chainlink getRoundData: the `_roundId` parameter is ignored
    ///         and the caller always receives the current exchange rate (the same data
    ///         `latestRoundData` would return). This oracle has no historical state —
    ///         the rate is computed on demand from the live vault accounting — so
    ///         returning current data is the only meaningful behavior. Consumers that
    ///         require strict historical lookups should use a different feed.
    function getRoundData(
        uint80 /* _roundId */
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
        answer = _scaledAnswer();
        return (
            uint80(block.number),
            answer,
            block.timestamp,
            block.timestamp,
            uint80(block.number)
        );
    }

    /// @dev Compute the 8-decimal Chainlink answer from the vault's 18-decimal
    ///      exchange rate. Reverts if the rate is so small it would truncate to
    ///      zero — Chainlink consumers expect strictly positive answers, and a
    ///      zero answer downstream can trigger mass liquidations or other
    ///      catastrophic behavior. Reverting forces the consumer to handle the
    ///      "feed broken" state explicitly instead of silently misreading.
    function _scaledAnswer() internal view returns (int256) {
        uint256 scaled = vault.exchangeRate() / 1e10;
        require(scaled > 0, "BILOracle: rate truncates to zero");
        return int256(scaled);
    }
}
