// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import "@aave/periphery-v3/contracts/misc/interfaces/IEACAggregatorProxy.sol";

interface IHDCLVault {
    function exchangeRate() external view returns (uint256);
}

/// @title HDCLOracleAdapter
/// @notice Chainlink-compatible oracle for HDCL/USD price.
///         Reads exchangeRate() from HDCLVault (18 decimals, HDCL→HOLLAR).
///         Since HOLLAR ≈ $1, the exchange rate is effectively HDCL/USD.
///         Scales the 18-decimal WAD value down to 8 decimals for Aave compatibility.
contract HDCLOracleAdapter is IEACAggregatorProxy {

    uint8 public constant decimals = 8;
    IHDCLVault public immutable vault;

    constructor(address _vault) {
        require(_vault != address(0), "Zero vault address");
        vault = IHDCLVault(_vault);
    }

    function latestAnswer() external view returns (int256) {
        uint256 rateWad = vault.exchangeRate(); // 18 decimals
        return int256(rateWad / 1e10); // scale 18 → 8 decimals
    }

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external view returns (uint256) {
        return block.number;
    }

    function getAnswer(uint256) external view returns (int256) {
        return this.latestAnswer();
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return block.timestamp;
    }
}
