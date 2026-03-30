// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {HDCLVault} from "../../../src/HDCLVault.sol";
import {MockHollar} from "../../mocks/MockHollar.sol";

/// @notice Simulates random user actions: deposit, requestRedeem, cancelRedeem.
contract UserHandler is Test {
    HDCLVault public vault;
    MockHollar public hollar;

    address[] public actors;
    uint256[] public activeRequestIds;
    mapping(uint256 => address) public requestOwner;

    // Ghost variables for cross-checking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalHdclMinted;
    uint256 public ghost_depositCount;
    uint256 public ghost_redeemRequestCount;

    constructor(HDCLVault _vault, MockHollar _hollar, address[] memory _actors) {
        vault = _vault;
        hollar = _hollar;
        actors = _actors;
    }

    // ── Deposit ────────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];

        uint256 balance = hollar.balanceOf(actor);
        if (balance < 10e18) return; // need at least min deposit

        // Bound amount to [10e18, balance] and respect TVL cap
        amount = bound(amount, 10e18, balance);
        uint256 remaining = 0;
        uint256 totalAssets = vault.totalAssets();
        uint256 tvlCap = vault.tvlCap();
        if (totalAssets + amount > tvlCap) {
            if (totalAssets >= tvlCap) return;
            remaining = tvlCap - totalAssets;
            if (remaining < 10e18) return;
            amount = remaining;
        }

        vm.prank(actor);
        uint256 hdcl = vault.deposit(amount);

        ghost_totalDeposited += amount;
        ghost_totalHdclMinted += hdcl;
        ghost_depositCount++;
    }

    // ── Request Redeem ─────────────────────────────────────────────────────

    function requestRedeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];

        uint256 hdclBal = vault.balanceOf(actor);
        uint256 minRedeem = vault.minRedeemAmount();
        if (hdclBal < minRedeem) return;

        amount = bound(amount, minRedeem, hdclBal);

        vm.prank(actor);
        uint256 requestId = vault.requestRedeem(amount);

        activeRequestIds.push(requestId);
        requestOwner[requestId] = actor;
        ghost_redeemRequestCount++;
    }

    // ── Cancel Redeem ──────────────────────────────────────────────────────

    function cancelRedeem(uint256 seed) external {
        if (activeRequestIds.length == 0) return;

        uint256 idx = seed % activeRequestIds.length;
        uint256 requestId = activeRequestIds[idx];
        address owner = requestOwner[requestId];

        // Check if still active
        (address user, , , bool active) = vault.getRedemptionRequest(requestId);
        if (!active || user == address(0)) {
            _removeRequestAt(idx);
            return;
        }

        vm.prank(owner);
        vault.cancelRedeem(requestId);
        _removeRequestAt(idx);
    }

    function _removeRequestAt(uint256 idx) internal {
        activeRequestIds[idx] = activeRequestIds[activeRequestIds.length - 1];
        activeRequestIds.pop();
    }

    function getActiveRequestCount() external view returns (uint256) {
        return activeRequestIds.length;
    }
}
