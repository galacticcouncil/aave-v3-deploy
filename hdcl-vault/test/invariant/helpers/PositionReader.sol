// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {HDCLVault} from "../../../src/HDCLVault.sol";

/// @notice Helper to read NFTPosition fields from the vault's public array getter.
///         Avoids assembly by using Solidity tuple destructuring in a separate contract.
contract PositionReader {
    HDCLVault public immutable vault;

    constructor(HDCLVault _vault) {
        vault = _vault;
    }

    function isStale(uint256 idx) external view returns (bool _isStale) {
        (,,,,,,, _isStale,,,,) = vault.positions(idx);
    }

    function staleValues(uint256 idx) external view returns (uint256 stalePrincipal, uint256 staleYield) {
        (,,,,,,,, stalePrincipal, staleYield,,) = vault.positions(idx);
    }

    function principal(uint256 idx) external view returns (uint256 _principal) {
        (, _principal,,,,,,,,,,) = vault.positions(idx);
    }

    function pendingYield(uint256 idx) external view returns (uint256 _pendingYield) {
        (,,,,,,,,,,, _pendingYield) = vault.positions(idx);
    }
}
