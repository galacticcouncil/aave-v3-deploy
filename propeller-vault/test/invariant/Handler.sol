// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {SubLoop} from "../../src/SubLoop.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {MockDcaScheduler} from "../mocks/MockDcaScheduler.sol";

/// @notice Randomized driver for the Propeller invariant suite. A single actor
///         (this handler) deposits, drives the deploy/unwind DCA + keeper pokes,
///         requests redemptions, settles and claims — in whatever order the
///         fuzzer picks. Ghost vars track quantities the invariants compare to.
contract Handler is Test {
    CollateralVault public vault;
    SubLoop public loop;
    MockPool public pool;
    MockDcaScheduler public dca;
    MockERC20 public eth;
    MockERC20 public prime;

    uint256 public ghostEscrowed; // pShares escrowed in open redemptions
    uint256[] public reqIds;

    constructor(
        CollateralVault _vault,
        SubLoop _loop,
        MockPool _pool,
        MockDcaScheduler _dca,
        MockERC20 _eth,
        MockERC20 _prime
    ) {
        vault = _vault;
        loop = _loop;
        pool = _pool;
        dca = _dca;
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

    // ── keeper + DCA: ramp the loop ──────────────────────────────────────────
    function ramp(uint256 n) external {
        n = bound(n, 1, 8);
        for (uint256 i = 0; i < n; i++) {
            uint256 oid = loop.deployOrderId();
            if (oid != 0 && dca.remaining(oid) > 0) dca.executeDeployFully(oid);
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

    // ── keeper + DCA: deleveraging spiral ─────────────────────────────────────
    function churnUnwind(uint256 n) external {
        uint256 uid = loop.unwindOrderId();
        if (uid == 0) return;
        n = bound(n, 1, 12);
        for (uint256 i = 0; i < n; i++) {
            if (prime.balanceOf(address(loop)) == 0) break;
            if (pool.maxWithdrawable(address(loop), address(prime)) == 0) break;
            dca.executeUnwind(uid);
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
            uint256 shares,
            , // collateralOwed
            , // debtShare
            , // synthShare
            , // repaid
            uint256 settled,
            bool active
        ) = vault.redemptions(id);
        if (!active || settled == 0) return;
        vault.claim(id, address(this));
        ghostEscrowed -= shares;
    }
}
