// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IDecentralPool
/// @notice Interface for Decentral Protocol's lending pool.
/// @dev The HDCL Vault interacts with this pool to deposit stablecoins,
///      manage position NFTs, and withdraw yield and principal.
interface IDecentralPool {
    /// @notice Deposits stablecoins into the lending pool and mints a position NFT.
    /// @param amount The amount of stablecoins to deposit (in stablecoin decimals).
    /// @return tokenId The ID of the newly minted position NFT representing the deposit.
    function deposit(uint256 amount) external returns (uint256 tokenId);

    /// @notice Requests a yield withdrawal for a given position NFT.
    /// @dev This initiates the yield withdrawal process; execution follows after the cooldown.
    /// @param tokenId The ID of the position NFT to withdraw yield from.
    function requestYieldWithdrawal(uint256 tokenId) external;

    /// @notice Executes a previously requested yield withdrawal.
    /// @dev Must be called after the yield withdrawal request cooldown has elapsed.
    /// @param tokenId The ID of the position NFT to execute the yield withdrawal for.
    function executeYieldWithdrawal(uint256 tokenId) external;

    /// @notice Requests a principal withdrawal for a given position NFT.
    /// @dev This initiates the principal withdrawal process; execution follows after the cooldown.
    /// @param tokenId The ID of the position NFT to withdraw principal from.
    function requestPrincipalWithdrawal(uint256 tokenId) external;

    /// @notice Executes a previously requested principal withdrawal.
    /// @dev Must be called after the principal withdrawal request cooldown has elapsed.
    /// @param tokenId The ID of the position NFT to execute the principal withdrawal for.
    function executePrincipalWithdrawal(uint256 tokenId) external;

    /// @notice Returns the fixed APY offered by the pool, expressed as a WAD (1e18 = 100%).
    /// @return The fixed APY as a WAD-scaled uint256.
    function fixedAPYWad() external view returns (uint256);

    /// @notice Returns the address of the stablecoin accepted by the pool.
    /// @return The ERC-20 stablecoin token address.
    function stablecoin() external view returns (address);

    /// @notice Returns the minimum deposit amount accepted by the pool.
    /// @return The minimum investment amount in stablecoin decimals.
    function minimumInvestmentAmount() external view returns (uint256);

    /// @notice Returns the maximum deposit amount accepted by the pool.
    /// @return The maximum investment amount in stablecoin decimals.
    function maximumInvestmentAmount() external view returns (uint256);
}
