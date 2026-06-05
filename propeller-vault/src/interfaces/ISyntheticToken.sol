// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ISyntheticToken
/// @notice Propeller-owned ERC20 used only as Aave collateral to floor the Main
///         position's health factor. Mint/burn gated to vault contracts
///         (MINTER_ROLE). Registered as an Aave reserve with LTV 0 / LT ~98% /
///         non-isolation / borrowing disabled / $1 oracle.
interface ISyntheticToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
