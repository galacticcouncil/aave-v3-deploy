// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {HDCLVault} from "../../../src/HDCLVault.sol";

/// @notice Simulates admin actions: markStale, unmarkStale.
contract AdminHandler is Test {
    HDCLVault public vault;
    address public admin;

    uint256 public ghost_markStaleCalls;
    uint256 public ghost_unmarkStaleCalls;

    constructor(HDCLVault _vault, address _admin) {
        vault = _vault;
        admin = _admin;
    }

    // ── Mark Position Stale ────────────────────────────────────────────────

    function markStale(uint256 positionSeed) external {
        uint256 count = vault.getPositionCount();
        if (count == 0) return;

        uint256 idx = positionSeed % count;
        (, , , , , uint8 state) = vault.getPosition(idx);

        // Must be in a stuck withdrawal state (1, 2, or 3) and not already stale/redeemed
        if (state < 1 || state > 3) return;

        vm.prank(admin);
        try vault.markPositionStale(idx) {
            ghost_markStaleCalls++;
        } catch {
            // Not eligible (delay not met, already stale, etc.)
        }
    }

    // ── Unmark Position Stale ──────────────────────────────────────────────

    function unmarkStale(uint256 positionSeed, bool backtrack) external {
        uint256 count = vault.getPositionCount();
        if (count == 0) return;

        uint256 idx = positionSeed % count;

        vm.prank(admin);
        try vault.unmarkPositionStale(idx, backtrack) {
            ghost_unmarkStaleCalls++;
        } catch {
            // Not stale
        }
    }
}
