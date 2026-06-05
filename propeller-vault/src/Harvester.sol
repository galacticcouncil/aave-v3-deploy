// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISubLoop} from "./interfaces/ISubLoop.sol";

/// @title Harvester
/// @notice Keeper entrypoint that orchestrates harvest / de-lever across the
///         shared SubLoop and the registered CollateralVaults. Each action
///         re-checks on-chain state (HF, carry) so keepers cannot trigger
///         unsafe operations — mirroring the on-chain-guarded keeper pattern of
///         pallet-hsm `execute_arbitrage` / pallet-liquidation `liquidate`.
///
/// @dev    STATUS: skeleton. Orchestration sequencing is marked TODO(impl).
contract Harvester is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    ISubLoop public immutable subLoop;
    address[] public vaults;

    event HarvestRun(uint256 surplus);
    event DeLeverRun();

    error ZeroAddress();

    constructor(address _subLoop, address admin) {
        if (_subLoop == address(0) || admin == address(0)) revert ZeroAddress();
        subLoop = ISubLoop(_subLoop);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function addVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        vaults.push(vault);
    }

    /// @notice Realize loop carry, then distribute each vault's pro-rata cut and
    ///         compound it back into that vault's collateral.
    function harvest(bytes[] calldata routes) external onlyRole(KEEPER_ROLE) {
        uint256 surplus = subLoop.harvest();
        // TODO(impl): split `surplus` by each vault's subLoop.sharesOf, then
        //   call CollateralVault.compound(cut, minOut, routes[i]) per vault.
        routes;
        emit HarvestRun(surplus);
    }

    /// @notice Trigger loop de-lever when HF is at/below the trigger.
    function deLever() external onlyRole(KEEPER_ROLE) {
        subLoop.deLever();
        emit DeLeverRun();
    }
}
