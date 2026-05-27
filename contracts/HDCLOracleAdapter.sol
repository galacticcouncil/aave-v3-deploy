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
///
///         Implements the FULL Chainlink V3 AggregatorV3Interface (in addition
///         to Aave's IEACAggregatorProxy) — required by Hydration's stableswap
///         pallet `MMOracle` peg-source resolver, which calls `latestRoundData`
///         (not just `latestAnswer`). Without this, `stableswap.create_pool_with_pegs`
///         errors with `MissingTargetPegOracle`.
contract HDCLOracleAdapter is IEACAggregatorProxy {

    uint8 public constant decimals = 8;
    uint256 public constant version = 4; // Chainlink V3 interface version
    IHDCLVault public immutable vault;

    constructor(address _vault) {
        require(_vault != address(0), "Zero vault address");
        vault = IHDCLVault(_vault);
    }

    // ---- Legacy IEACAggregatorProxy methods (used by Aave's AaveOracle) ----

    function latestAnswer() public view returns (int256) {
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

    // ---- Chainlink V3 AggregatorV3Interface (used by stableswap MMOracle) ----

    function description() external pure returns (string memory) {
        return "HDCL / USD";
    }

    /// @notice Vault.exchangeRate is monotonically updated every block, so
    ///         every read effectively returns the "current round" with no
    ///         meaningful history. We return the same shape for any roundId.
    function getRoundData(uint80 _roundId)
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
        return _roundData(_roundId);
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
        return _roundData(uint80(block.number));
    }

    function _roundData(uint80 _roundId)
        internal
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = _roundId;
        answer = latestAnswer();
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = _roundId;
    }
}
