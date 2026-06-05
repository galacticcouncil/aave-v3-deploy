// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IFlashLoanSimpleReceiver
/// @notice Aave v3 simple flash-loan callback. SubLoop implements this to open
///         / unwind looped positions atomically in a single transaction.
interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
