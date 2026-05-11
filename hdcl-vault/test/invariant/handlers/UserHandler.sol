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
    // Coverage counters for the slippage-floor paths added to requestRedeem.
    // Used by InvariantVaultTest's call summary to confirm fuzz actually
    // exercises the cap (rejection) and park-eligible (non-zero floor accepted)
    // code paths — silence in those counters indicates a coverage gap.
    uint256 public ghost_redeemFloorAccepted;
    uint256 public ghost_redeemCapRejected;

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

    /// @notice Fuzz `requestRedeem` across the four floor strategies the
    ///         contract has to handle. `floorStrategy` is fuzzed so each
    ///         path is exercised over many runs:
    ///           0 — no floor (legacy path)
    ///           1 — floor below current rate (passes cap; will fulfill
    ///               normally as long as rate stays above)
    ///           2 — floor exactly at current rate (boundary — passes cap)
    ///           3 — floor above current rate (must revert at the cap)
    ///         Strategy 3 is wrapped in try/catch so the cap revert doesn't
    ///         abort the fuzz call — that's the whole point of testing it.
    function requestRedeem(
        uint256 actorSeed,
        uint256 amount,
        uint256 floorStrategy
    ) external {
        address actor = actors[actorSeed % actors.length];

        uint256 hdclBal = vault.balanceOf(actor);
        uint256 minRedeem = vault.minRedeemAmount();
        if (hdclBal < minRedeem) return;

        amount = bound(amount, minRedeem, hdclBal);

        uint256 minRateWad;
        uint256 strategy = floorStrategy % 4;
        if (strategy == 1) {
            // 90–99% of current rate. Sub-percent slack lets time-driven
            // yield drift keep the floor satisfiable in the common case but
            // makes the entry parking-eligible on rare rate dips.
            uint256 rate = vault.exchangeRate();
            uint256 pct = 90 + (floorStrategy % 10); // 90..99
            minRateWad = (rate * pct) / 100;
        } else if (strategy == 2) {
            // Boundary: floor == current rate.
            minRateWad = vault.exchangeRate();
        } else if (strategy == 3) {
            // Above current rate — submission MUST revert at the cap.
            minRateWad = vault.exchangeRate() + 1;
        }

        vm.prank(actor);
        try vault.requestRedeem(amount, minRateWad) returns (uint256 requestId) {
            activeRequestIds.push(requestId);
            requestOwner[requestId] = actor;
            ghost_redeemRequestCount++;
            if (minRateWad > 0) ghost_redeemFloorAccepted++;
        } catch {
            // Expected: strategy 3 always reverts (cap). Other reverts
            // (e.g., paused, exceeds cap) are also tolerated since fuzzing
            // can hit those edge states.
            if (strategy == 3) ghost_redeemCapRejected++;
        }
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
