// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BILVault} from "../../../src/BILVault.sol";

/// @notice Helper to read NFTPosition fields from the vault's public array getter.
///         Avoids assembly by using Solidity tuple destructuring in a separate contract.
contract PositionReader {
    BILVault public immutable vault;

    constructor(BILVault _vault) {
        vault = _vault;
    }

    function principal(uint256 idx) external view returns (uint256 _principal) {
        (, _principal,,,,,,,) = vault.positions(idx);
    }

    function pendingYield(uint256 idx) external view returns (uint256 _pendingYield) {
        (,,,,,,,, _pendingYield) = vault.positions(idx);
    }
}
