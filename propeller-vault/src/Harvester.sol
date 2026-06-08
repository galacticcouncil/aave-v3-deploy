// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISubLoop} from "./interfaces/ISubLoop.sol";

interface ICompoundable {
    function compound(address tokenIn, uint256 amountIn, uint256 minOut, bytes calldata route) external;
}

/// @title Harvester
/// @notice Keeper entrypoint orchestrating harvest / de-lever across the shared
///         SubLoop and the registered CollateralVaults. `harvest` skims the loop
///         carry (surplus PRIME), splits it pro-rata by each vault's loop shares,
///         and compounds each cut into that vault's collateral (in-kind yield).
contract Harvester is AccessControl {
    using SafeERC20 for IERC20;

    // KEEPER_ROLE removed: harvest/deLever are permissionless. DEFAULT_ADMIN_ROLE
    // is retained for addVault (registry management).

    ISubLoop public immutable subLoop;
    IERC20 public immutable prime; // the token SubLoop.harvest returns
    address[] public vaults;

    event HarvestRun(uint256 surplusPrime);
    event DeLeverRun();

    error ZeroAddress();

    constructor(address _subLoop, address _prime, address admin) {
        if (_subLoop == address(0) || _prime == address(0) || admin == address(0)) revert ZeroAddress();
        subLoop = ISubLoop(_subLoop);
        prime = IERC20(_prime);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function addVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        vaults.push(vault);
    }

    /// @notice Skim loop carry → distribute PRIME pro-rata by loop shares →
    ///         compound each vault's cut into its collateral.
    /// @param minOuts per-vault min collateral out (slippage bound); pass 0s in tests.
    function harvest(uint256[] calldata minOuts) external {
        subLoop.harvest(); // PRIME → this Harvester (routed via SubLoop.harvester)
        // distribute the FULL balance, not just this call's skim — a direct
        // SubLoop.harvest() caller may have parked PRIME here; nothing strands.
        uint256 surplus = prime.balanceOf(address(this));
        if (surplus == 0) {
            emit HarvestRun(0);
            return;
        }
        uint256 total = subLoop.totalShares();
        uint256 n = vaults.length;
        uint256 registeredShares;
        for (uint256 i = 0; i < n; i++) {
            address v = vaults[i];
            uint256 vShares = subLoop.sharesOf(v);
            registeredShares += vShares;
            uint256 cut = total == 0 ? 0 : (surplus * vShares) / total;
            if (cut == 0) continue;
            prime.forceApprove(v, 0);
            prime.forceApprove(v, cut);
            ICompoundable(v).compound(address(prime), cut, i < minOuts.length ? minOuts[i] : 0, "");
        }
        // pro-rata fairness: every share-holding vault must be registered, else
        // its slice would silently strand. Fail loud on a stale registry.
        require(registeredShares == total, "vault set incomplete");
        emit HarvestRun(surplus);
    }

    /// @notice Trigger loop de-lever when HF is at/below the trigger.
    function deLever() external {
        subLoop.deLever();
        emit DeLeverRun();
    }
}
