// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IAavePool
/// @notice Minimal subset of the Aave v3 Pool surface Propeller uses.
///         Verified against the live Hydration money market Pool
///         (0x1b02e051683b5cfac5929c25e84adb26ecf87b38).
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @param interestRateMode 2 = variable (the only mode Propeller uses)
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    /// @return totalCollateralBase, totalDebtBase, availableBorrowsBase,
    ///         currentLiquidationThreshold, ltv, healthFactor (1e18 = HF 1.0)
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);

    /// @notice The PoolAddressesProvider for this market — used to resolve the
    ///         price oracle for manipulation-resistant swap min-out sizing.
    function ADDRESSES_PROVIDER() external view returns (address);
}

/// @notice Minimal Aave PoolAddressesProvider surface.
interface IPoolAddressesProvider {
    function getPriceOracle() external view returns (address);
}

/// @notice Minimal AaveOracle surface. Returns the asset price in the market's
///         base currency (USD, 8 decimals) — the same feed Aave uses for HF, so
///         it resists pool-spot manipulation.
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}
