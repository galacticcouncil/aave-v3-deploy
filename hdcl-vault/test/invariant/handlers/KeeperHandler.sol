// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {HDCLVault} from "../../../src/HDCLVault.sol";
import {MockDecentralPool} from "../../mocks/MockDecentralPool.sol";

/// @notice Simulates keeper bot actions: time warps, pokeDecentral, pokeQueue.
///         Also simulates the Decentral approver (yield/principal approvals).
contract KeeperHandler is Test {
    HDCLVault public vault;
    MockDecentralPool public pool;

    // Track the last exchange rate for monotonicity checks
    uint256 public lastExchangeRate;

    // Ghost variables
    uint256 public ghost_pokeDecentralCalls;
    uint256 public ghost_pokeQueueCalls;
    uint256 public ghost_timeWarps;

    constructor(HDCLVault _vault, MockDecentralPool _pool) {
        vault = _vault;
        pool = _pool;
        lastExchangeRate = vault.exchangeRate();
    }

    // ── Time Warp ──────────────────────────────────────────────────────────

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 hours, 70 days);
        vm.warp(block.timestamp + seconds_);
        ghost_timeWarps++;
        _checkRate();
    }

    // ── Poke Decentral ─────────────────────────────────────────────────────

    function pokeDecentral(uint256 positionSeed) external {
        uint256 count = vault.getPositionCount();
        if (count == 0) return;

        uint256 idx = positionSeed % count;

        // Skip if already redeemed
        (, , , , , uint8 state) = vault.getPosition(idx);
        if (state == 4) return;

        vault.pokeDecentral(idx);
        ghost_pokeDecentralCalls++;
        _checkRate();
    }

    // ── Approve Yield ──────────────────────────────────────────────────────

    function approveYield(uint256 positionSeed) external {
        uint256 count = vault.getPositionCount();
        if (count == 0) return;

        uint256 idx = positionSeed % count;
        (, , , , , uint8 state) = vault.getPosition(idx);

        // Only approve if in YieldWithdrawalRequested
        if (state != 1) return;

        (uint256 tokenId, , , , , ) = vault.getPosition(idx);
        pool.approveYieldWithdrawal(tokenId);
    }

    // ── Approve Principal ──────────────────────────────────────────────────

    function approvePrincipal(uint256 positionSeed) external {
        uint256 count = vault.getPositionCount();
        if (count == 0) return;

        uint256 idx = positionSeed % count;
        (, , , , , uint8 state) = vault.getPosition(idx);

        // Only approve if in PrincipalWithdrawalRequested
        if (state != 3) return;

        (uint256 tokenId, , , , , ) = vault.getPosition(idx);
        pool.approvePrincipalWithdrawal(tokenId);
    }

    // ── Poke Queue ─────────────────────────────────────────────────────────

    function pokeQueue() external {
        vault.pokeQueue();
        ghost_pokeQueueCalls++;
        _checkRate();
    }

    // ── Rate Tracking ──────────────────────────────────────────────────────

    /// @dev Update lastExchangeRate after each action. The invariant test
    ///      reads this to check monotonicity with tolerance.
    function _checkRate() internal {
        lastExchangeRate = vault.exchangeRate();
    }
}
