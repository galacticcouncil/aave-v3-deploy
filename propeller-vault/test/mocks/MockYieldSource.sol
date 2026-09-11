// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";

/// @notice A minimal, NON-leveraged `IYieldSource` — the point of the seam. It
///         has no health factor, no Aave, no PRIME, no keeper cranks: it just
///         custodies the HOLLAR handed to it 1:1 and frees it synchronously on
///         request. If `CollateralVault` can deposit into and redeem through this
///         with zero code changes, then PRIME is genuinely pluggable (the vault
///         binds only to `IYieldSource`, not to the leveraged loop).
///
/// @dev    Shares are 1:1 with HOLLAR (no yield modelled — this is a seam test,
///         not a yield test). `requestUnwind` frees the whole slice immediately;
///         `pullFreed` pays it out.
contract MockYieldSource is IYieldSource {
    IERC20 public immutable hollar;

    mapping(address => uint256) internal _shares;
    mapping(address => uint256) internal _freed;
    uint256 internal _totalShares;

    constructor(address _hollar) {
        hollar = IERC20(_hollar);
    }

    function deposit(uint256 hollarAmount) external returns (uint256 shares) {
        hollar.transferFrom(msg.sender, address(this), hollarAmount);
        shares = hollarAmount; // 1:1
        _shares[msg.sender] += shares;
        _totalShares += shares;
    }

    function requestUnwind(uint256 shares) external returns (uint256 unwindId) {
        require(_shares[msg.sender] >= shares, "insufficient shares");
        _shares[msg.sender] -= shares;
        _totalShares -= shares;
        _freed[msg.sender] += shares; // 1:1, freed synchronously
        return 0;
    }

    function pullFreed() external returns (uint256 hollarSent) {
        hollarSent = _freed[msg.sender];
        if (hollarSent == 0) return 0;
        _freed[msg.sender] = 0;
        hollar.transfer(msg.sender, hollarSent);
    }

    function freedOf(address vault) external view returns (uint256) {
        return _freed[vault];
    }

    function pendingUnwindOf(address vault) external view returns (uint256) {
        // frees synchronously into _freed, so anything still owed is unpulled-freed
        return _freed[vault];
    }

    function equityOf(address vault) external view returns (uint256) {
        // equity in USD8; HOLLAR is 18dp $1, shares 1:1 → /1e10
        return _shares[vault] / 1e10;
    }

    function sharesOf(address vault) external view returns (uint256) {
        return _shares[vault];
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    function totalEquity() external view returns (uint256) {
        return _totalShares / 1e10;
    }

    function negativeCarryBps() external pure returns (uint256) {
        return 0; // 1:1 custody, no yield/loss modelled → never underwater
    }

    function harvest() external returns (uint256 surplus) {
        return 0; // no yield modelled
    }
}
