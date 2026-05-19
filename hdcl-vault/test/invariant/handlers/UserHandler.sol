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
    uint256 public ghost_claimCount;
    uint256 public ghost_totalAssetsClaimed;
    uint256 public ghost_autoClaimToggles;
    uint256 public ghost_operatorSets;

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
        uint256 hdcl = vault.deposit(amount, actor);

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
        try vault.requestRedeem(amount, actor, actor) returns (uint256 requestId) {
            activeRequestIds.push(requestId);
            requestOwner[requestId] = actor;
            ghost_redeemRequestCount++;
        } catch {
            // Tolerate reverts under fuzz-driven edge states (e.g. paused,
            // TVL transitions) so the run keeps progressing.
        }
    }

    // ── Cancel Redeem ──────────────────────────────────────────────────────

    function cancelRedeem(uint256 seed) external {
        if (activeRequestIds.length == 0) return;

        uint256 idx = seed % activeRequestIds.length;
        uint256 requestId = activeRequestIds[idx];
        address owner = requestOwner[requestId];

        // Check if still active
        (address user, , , , bool active) = vault.getRedemptionRequest(requestId);
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

    // ── Claim (pull-redemption) ────────────────────────────────────────────

    /// @notice Pick a random actor and a random share count up to their
    ///         current claimable inventory, then `redeem`. Exercises the
    ///         pull-redemption path so the invariants see real claim flows.
    function claim(uint256 actorSeed, uint256 shareSeed) external {
        address actor = actors[actorSeed % actors.length];

        // Sum the actor's claimable across all open requests.
        uint256 totalClaimable;
        uint256 tail = vault.getRedemptionQueueLength();
        for (uint256 i = 0; i < tail; i++) {
            (address u,, uint256 settled,,) = vault.getRedemptionRequest(i);
            if (u == actor) totalClaimable += settled;
        }
        if (totalClaimable == 0) return;

        uint256 shares = bound(shareSeed, 1, totalClaimable);

        vm.prank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256 assets) {
            ghost_claimCount++;
            ghost_totalAssetsClaimed += assets;
        } catch {
            // Tolerate transient reverts under fuzz (paused vault, etc.)
        }
    }

    // ── Auto-claim opt-in toggle ───────────────────────────────────────────

    function toggleAutoClaim(uint256 actorSeed, bool enable) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        vault.setAutoClaim(enable);
        ghost_autoClaimToggles++;
    }

    // ── Operator approval toggle ───────────────────────────────────────────

    function toggleOperator(uint256 ownerSeed, uint256 opSeed, bool approve) external {
        address owner = actors[ownerSeed % actors.length];
        address op = actors[opSeed % actors.length];
        if (op == owner) return; // self-operator is a no-op
        vm.prank(owner);
        vault.setOperator(op, approve);
        ghost_operatorSets++;
    }
}
