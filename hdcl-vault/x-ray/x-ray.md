# X-Ray Report

> HDCL Vault (Hydrated Decentral) | `feat/hdcl-vault` @ `9d49425` | Foundry
> Date: 2026-05-19
> Spec: `.claude/HDCL-vault-specification.md`; in-tree design: `PLAN-multi-pool.md`

---

## 1. Protocol Overview

**What it does:** A fungible ERC-20 yield-bearing wrapper around Decentral Protocol's fixed-rate NFT lending positions, converting illiquid time-locked NFTs into a single liquid hDCL token. Conforms to **ERC-4626** on the deposit side and **ERC-7540** (async redeem) on the withdraw side.

- **Users**: deposit HOLLAR, receive hDCL at the current `exchangeRate()`; redeem via a FIFO async queue backed by Decentral position maturity.
- **Multi-pool**: vault holds a registry of Decentral pools (multiple APYs simultaneously). New deposits route to `activeDepositPool`; each existing position is anchored to its origin pool via `positionPool[positionIndex]`. APY is locked at deposit — pool-side rate changes can't retro-affect prior positions.
- **Pull redemption**: `requestRedeem` escrows hDCL; keeper settle (`pokeQueue` / cascaded from `pokeDecentral`) rate-locks HOLLAR into `totalReservedHollar`. Users (or delegates) then call `redeem` / `withdraw` to pull the funds.
- **Auto-claim UX**: opt-in `setAutoClaim(true)` lets any `CLAIM_OPERATOR_ROLE` holder call `redeem` on the user's behalf with `receiver == controller` — restores push-like UX without sacrificing 7540 conformance at the contract layer.

### Contracts in Scope

| Subsystem | Contract | Role |
|-----------|----------|------|
| Vault Core | `HDCLVault.sol` (1701 lines) | ERC-20 + ERC-4626 + ERC-7540, multi-pool routing, position lifecycle, redemption queue with rate-lock |
| Oracle | `WDCLOracle.sol` (106 lines) | Chainlink-compatible feed for external consumers (Aave hub) |

### Key Mechanisms

- **Non-rebasing exchange rate**: hDCL value appreciates against HOLLAR via `totalAssets() / totalSupply()`.
- **Heterogeneous yield accrual** (multi-pool): O(1) via global `yieldRateSum` (Σ apy×principal) and `yieldOffsetSum` (Σ apy×principal×yieldStartTime). Each pool's APY is captured into the per-position snapshot at deposit.
- **Rate-lock on settle**: when keeper settles a queued request, the HOLLAR owed at *that* exchange rate is reserved into `totalReservedHollar`. The user's later claim transfers exactly that amount — they don't take an additional rate hit and they don't continue to accrue yield on the settled portion.

---

## 2. Roles & Trust Model

| Role | Holder (intended) | Capabilities |
|------|-------------------|-------------|
| `ADMIN_ROLE` | Hydration governance *economics-parameters* track | TVL cap, pool registry, oracle, min-amounts, pause (all instant) |
| `GUARDIAN_ROLE` | Hydration *technical committee* | Pause / unpause (deposits and full). Symmetric with admin on pause levers — fast response without economics-params authority |
| `UPGRADER_ROLE` | Hydration governance | UUPS upgrade (instant; no on-chain timelock) |
| `DEFAULT_ADMIN_ROLE` | governance | Grant/revoke roles |
| `CLAIM_OPERATOR_ROLE` | Keeper bot(s) | Call `redeem`/`withdraw` on opted-in users with `receiver == controller` |

### Trust Boundaries

1. **Vault ↔ Decentral Pool (per pool)**: trusted. Every Decentral entry call wrapped in try/catch — a paused/broken pool degrades to no-op rather than locking positions.
2. **Admin boundary**: instant. *No fund extraction path* — no admin-callable transfer of HOLLAR or NFTs.
3. **Guardian boundary**: pause/unpause only. Cannot move funds or alter economics.
4. **Upgrader boundary**: full power via UUPS replace. Highest privilege.
5. **Oracle boundary**: `setOracle` instantly redirects external consumers (Aave).

### Adversary Ranking

1. **Compromised admin/upgrader** — instant unrestricted upgrade or oracle redirect.
2. **Share inflation attacker** — mitigated: `DEAD_SHARES = 1000` + `totalAssets()` uses internal accounting (not `balanceOf`), donation-resistant.
3. **Queue griefer** — `minRedeemAmount` floor + bounded iteration budget per `pokeQueue` call.
4. **Decentral failure** (single-pool deployments) — try/catch isolates the position; positions in other registered pools remain unaffected.

---

## 3. Invariants

### Encoded as fuzz invariants (`test/invariant/InvariantVault.t.sol`)

15 properties × 256 runs × 50 calls each — all passing at `9d49425`:

| ID | Property |
|----|----------|
| INV-1..8  | Position state monotonicity; supply / totalAssets relationships; idle-HOLLAR ≤ vault balance; queue total ≤ vault hDCL balance; rate monotonicity in normal operation |
| INV-9     | (updated) Per-position pool-registry integrity |
| INV-10    | `totalReservedHollar == Σ request.hollarOwed` |
| INV-11    | `totalQueuedHdcl == Σ (request.hdclAmount − request.hdclSettled)` for live requests |
| INV-12    | `hollar.balanceOf(vault) >= idleHollar + totalReservedHollar` |
| INV-13    | Per-request consistency (`hdclSettled ≤ hdclAmount`; `hollarOwed > 0 ⟹ hdclSettled > 0`) |
| INV-14    | Non-Redeemed position ⟹ `positionPool[i]` is in pool registry |

### Stated invariants (per spec)

- No admin extraction (no `withdrawNFT` / no `transferHollar` admin function)
- Donation resistance (`totalAssets()` is purely accounting-based)
- Queue rate neutrality — escrowed hDCL is not burned at request; rate is locked at settle, not at request
- APY is locked per-position at deposit (Decentral primitive — verified independently in `../decentral-contracts`)

---

## 4. Test Analysis

| Metric | Value |
|--------|-------|
| Test files | 25 unit + 1 invariant |
| Test functions | 326 unit + invariant + handler |
| Total tests passing | 344 / 344 |
| Line coverage (HDCLVault) | **99.20%** (497/501) |
| Statement coverage | 97.14% |
| Branch coverage | 81.53% |
| Function coverage | **100%** (71/71) |
| WDCLOracle | **100%** lines / statements / branches / functions |

The 4 uncovered lines are foundry attribution artifacts on `external pure { return 0; }` view functions (`maxWithdraw`, `maxRedeem`, `previewWithdraw`) plus the `getEstimatedWaitTime` overflow fallback (`type(uint256).max`).

### Test depth by category

| Category | Count | What it covers |
|----------|-------|----------------|
| Unit | 25 files | Deposit, mint, redeem/withdraw, requestRedeem, cancel, exchange rate, queue mechanics, partial settle rounding, principal mismatch, oracle (incl. pause + zero-answer + decimals), first-depositor inflation, position lifecycle (incl. try/catch arms), reinvest, multi-pool registry, multi-pool heterogeneous APY (18% / 22% / 16% rate cut), operator + auto-claim, ERC-4626 surface, ERC-7540 views + ERC-165 |
| Stateful fuzz | 1 file, 15 invariants | UserHandler (deposit / requestRedeem / cancel / claim / setOperator / setAutoClaim) + KeeperHandler (poke + approve + warp + shortfall injection) |
| Formal | 0 | — |

---

## 5. Architecture Highlights

### Deposit flow

```
User.deposit(assets, receiver)
  ├─ TVL check: totalAssets() + assets <= tvlCap
  ├─ shares = previewDeposit(assets)
  ├─ hollar.safeTransferFrom(user → vault)
  ├─ _mint(receiver, shares)
  ├─ activeDepositPool.deposit(assets) → tokenId
  └─ positions.push(...); positionPool[i] = activeDepositPool;
     yieldRateSum / yieldOffsetSum updated with this pool's APY
```

### Multi-pool routing

- `pools[]` registry + `isPoolRegistered[address]` boolean
- `activeDepositPool` — current deposit/reinvest target; switched by admin via `setActiveDepositPool`
- `positionPool[positionIndex]` — anchors each position to its origin pool so `pokeDecentral` interacts with the right pool, regardless of what's currently active

### Pull-redemption with rate-lock

```
requestRedeem      → escrow hDCL, append to queue                     (no burn, no transfer)
[time passes, keeper or position maturity triggers]
pokeQueue / pokeDecentral
  └─ _processQueueWithHollar
        ├─ rate = exchangeRate()                                       (computed once per batch)
        ├─ for each unsettled queued entry, in FIFO:
        │   └─ hollarOwed = (pending × rate) / WAD
        │      settle as much as idle allows; partial settles accumulate
        ├─ idleHollar       -= settled HOLLAR
        └─ totalReservedHollar += settled HOLLAR
redeem / withdraw  → burn settled hDCL, transfer HOLLAR from reserved
```

---

## 6. Spec Deviations (deltas from original spec)

These are *intentional* and supersede the original `.claude/HDCL-vault-specification.md`:

| # | Change | Driver |
|---|--------|--------|
| 1 | ERC-4626 / ERC-7540 conformance with `supportsInterface` | Composability with the broader async-vault tooling ecosystem |
| 2 | Multi-pool support (`pools[]`, `activeDepositPool`, `positionPool[]`) | Decentral pool's APY is immutable per-pool — multi-pool is the way to operate over long horizons through rate changes |
| 3 | Pull redemption with rate-lock + `totalReservedHollar` | 7540 conformance; rate-lock is mandatory once HOLLAR is set aside |
| 4 | `GUARDIAN_ROLE` (pause-only, parallel to ADMIN) | Two-tier governance — slow econ-params vs. fast technical committee |
| 5 | `CLAIM_OPERATOR_ROLE` with user opt-in (`autoClaimEnabled`) | Restore push-like UX without breaking 7540 contract guarantees |
| 6 | Stale-position machinery (markPositionStale / withdrawalDelay) **removed** | Try/catch + UUPS upgrade path covers the "Decentral is broken" scenarios without the in-contract recognition state machine |
| 7 | Slippage parameter **removed** from deposit | Rate-lock model + accounting-based `totalAssets()` makes deposit MEV-irrelevant |
| 8 | Storage gap (`uint256[50] private __gap`) | UUPS upgrade safety |
| 9 | `cancelRedeem` refunds **unsettled portion only** | Settled hDCL belongs to the rate-locked HOLLAR reservation; can't unwind |

---

## 7. Known Limitations / Open Items

- **No on-chain timelock** on admin actions or UUPS upgrades. Mitigated by governance process at the role-holder level (Hydration governance tracks).
- **Single-active-pool routing** — only one `activeDepositPool` at a time. Admin picks. (Locked decision per `PLAN-multi-pool.md`.)
- **`retirePool` requires zero open positions** in that pool — operational migration is admin-orchestrated (drain via maturity), not automatic.
- **Oracle staleness not enforced** in `getOraclePrice` — only positive-answer check.

---

## X-Ray Verdict

**MATURE** — 344 tests passing with 99.2% line coverage, 100% function coverage, and 15 stateful invariants over 12,800 fuzz calls each. ERC-4626 + ERC-7540 conformance verified at interface level. Multi-pool heterogeneous APY (incl. rate cuts) covered end-to-end. Try/catch isolation around every Decentral interaction, with both catch arms of `pokeDecentral` now exercised.

**Structural facts:**

1. ~1807 lines of in-scope source (HDCLVault 1701 + WDCLOracle 106)
2. 344 tests across 25 unit files + 1 invariant file, all green at `9d49425`
3. UUPS upgradeable with `__gap[50]`, no on-chain timelock
4. Pull-redemption + rate-lock (7540-conformant), with role-gated auto-claim as a UX layer on top
5. Multi-pool registry with admin-only deposit routing; per-position pool anchoring keeps existing positions independent of routing changes
6. Two-tier governance: ADMIN (econ-params, instant) + GUARDIAN (pause-only, instant, parallel)
