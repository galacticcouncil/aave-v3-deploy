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

    /// @notice Aave v3 simple flash loan — borrow `asset`, repay `amount + premium`
    ///         inside the receiver's `executeOperation`.
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /// @return the variable-debt token balance helper via getReserveData would
    ///         be heavier; Propeller reads debt through getUserAccountData and
    ///         the debt-token directly where it needs per-asset granularity.
    function getReserveData(address asset) external view returns (bytes memory);
}
