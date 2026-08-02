// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {BILVault} from "../../../src/BILVault.sol";
import {MockHollar} from "../../mocks/MockHollar.sol";

/// @notice Simulates random user actions: deposit, requestRedeem, cancelRedeem.
contract UserHandler is Test {
    BILVault public vault;
    MockHollar public hollar;

    address[] public actors;
    uint256[] public activeRequestIds;
    mapping(uint256 => address) public requestOwner;

    // Ghost variables for cross-checking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalBilMinted;
    uint256 public ghost_depositCount;
    uint256 public ghost_redeemRequestCount;
    uint256 public ghost_claimCount;
    uint256 public ghost_totalAssetsClaimed;
    uint256 public ghost_autoClaimToggles;
    uint256 public ghost_operatorSets;

    constructor(BILVault _vault, MockHollar _hollar, address[] memory _actors) {
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
        uint256 bil = vault.deposit(amount, actor);

        ghost_totalDeposited += amount;
        ghost_totalBilMinted += bil;
        ghost_depositCount++;
    }

    // ── Request Redeem ─────────────────────────────────────────────────────

    function requestRedeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];

        uint256 bilBal = vault.balanceOf(actor);
        uint256 minRedeem = vault.minRedeemAmount();
        if (bilBal < minRedeem) return;

        amount = bound(amount, minRedeem, bilBal);

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
        (address user, , , , bool active,) = vault.getRedemptionRequest(requestId);
        if (!active || user == address(0)) {
            _removeRequestAt(idx);
            return;
        }

        vm.prank(owner);
        vault.cancelRedeem(requestId);
        _removeRequestAt(idx);
    }

    // ── Queue fills ────────────────────────────────────────────────────────

    address internal constant FILLER = address(0xF111e5);

    /// @notice Random controller lists (or re-prices / delists) a random
    ///         active request.
    function setFillAsk(uint256 seed, uint32 askBps) external {
        if (activeRequestIds.length == 0) return;
        uint256 requestId = activeRequestIds[seed % activeRequestIds.length];
        address owner = requestOwner[requestId];
        (address user, , , , bool active,) = vault.getRedemptionRequest(requestId);
        if (!active || user == address(0)) return;

        // Mostly valid asks, occasionally the delist sentinel.
        askBps = askBps % 100 == 0 ? type(uint32).max : askBps % 2_001;

        vm.prank(owner);
        try vault.setFillAsk(requestId, askBps) {
            ghost_askSets++;
        } catch {
            // NothingPending on fully-settled entries etc. — fine.
        }
    }

    /// @notice A dedicated filler buys listed queue entries head-first.
    function fillQueue(uint256 budget, uint32 minAskBps) external {
        budget = bound(budget, 1e18, 500_000e18);
        minAskBps = minAskBps % 2_001;

        hollar.mint(FILLER, budget);
        vm.prank(FILLER);
        hollar.approve(address(vault), budget);

        vm.prank(FILLER);
        try vault.fillQueue(budget, minAskBps) returns (uint256 spent, uint256 got) {
            ghost_hollarFilled += spent;
            ghost_bilFilled += got;
            ghost_fillCount++;
        } catch {
            // NothingFilled / paused / backlog — fine under fuzz.
        }
    }

    uint256 public ghost_askSets;
    uint256 public ghost_fillCount;
    uint256 public ghost_hollarFilled;
    uint256 public ghost_bilFilled;

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
        uint256 tail = vault.queueTail();
        for (uint256 i = 0; i < tail; i++) {
            (address u,, uint256 settled,,,) = vault.getRedemptionRequest(i);
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
