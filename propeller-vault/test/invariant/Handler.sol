// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {SubLoop} from "../../src/SubLoop.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool} from "../mocks/MockPool.sol";

/// @notice Randomized driver for the Propeller invariant suite. A single actor
///         (this handler) deposits, drives the deploy/unwind DCA + keeper pokes,
///         requests redemptions, settles and claims — in whatever order the
///         fuzzer picks. Ghost vars track quantities the invariants compare to.
contract Handler is Test {
    CollateralVault public vault;
    SubLoop public loop;
    MockPool public pool;
    MockERC20 public eth;
    MockERC20 public prime;

    uint256 public ghostEscrowed; // pShares escrowed in open redemptions
    uint256[] public reqIds;

    constructor(
        CollateralVault _vault,
        SubLoop _loop,
        MockPool _pool,
        MockERC20 _eth,
        MockERC20 _prime
    ) {
        vault = _vault;
        loop = _loop;
        pool = _pool;
        eth = _eth;
        prime = _prime;
    }

    // ── user: deposit ───────────────────────────────────────────────────────
    function deposit(uint256 amt) external {
        uint256 cap = vault.tvlCap();
        uint256 used = vault.totalAssets();
        if (used >= cap) return;
        amt = bound(amt, 1e15, cap - used);
        eth.mint(address(this), amt);
        eth.approve(address(vault), amt);
        vault.deposit(amt, address(this));
    }

    // ── keeper: ramp the loop (each poke borrows + levers a tranche) ─────────
    function ramp(uint256 n) external {
        n = bound(n, 1, 8);
        for (uint256 i = 0; i < n; i++) {
            loop.pokeBorrow();
        }
    }

    // ── user: request redemption ──────────────────────────────────────────────
    function requestRedeem(uint256 seed) external {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        uint256 id = vault.requestRedeem(shares, address(this));
        reqIds.push(id);
        ghostEscrowed += shares;
    }

    // ── keeper: deleveraging spiral (pokeRepay sells + repays per call) ───────
    function churnUnwind(uint256 n) external {
        if (loop.unwindTargetEquity() == 0) return;
        n = bound(n, 1, 12);
        for (uint256 i = 0; i < n; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
    }

    // ── keeper: settle queued redemptions ─────────────────────────────────────
    function settle() external {
        vault.pokeSettle();
    }

    // ── user: claim a settled request ─────────────────────────────────────────
    function claim(uint256 seed) external {
        uint256 len = reqIds.length;
        if (len == 0) return;
        uint256 id = reqIds[bound(seed, 0, len - 1)];
        (
            , // owner
            , // shares
            , // collateralOwed
            , // debtShare
            , // synthShare
            , // repaid
            uint256 settled,
            , // sharesBurned
            bool active
        ) = vault.redemptions(id);
        if (!active || settled == 0) return;
        // claim may be partial: shares are burned only in proportion to the
        // collateral paid, so track the ACTUAL burn (escrow balance delta)
        // rather than assuming the whole request closes.
        uint256 escrowBefore = vault.balanceOf(address(vault));
        vault.claim(id, address(this));
        ghostEscrowed -= (escrowBefore - vault.balanceOf(address(vault)));
    }
}
