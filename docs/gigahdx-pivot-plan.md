# GIGAHDX Design Pivot — EVM-side Plan

**Date:** 2026-05-06
**Author:** iamyxsh (with Claude)
**Audience:** Martin, mrq, Ben — please poke holes
**Scope:** EVM (`aave-v3-deploy`) only.
**Status:** Updated 13:05 CET — Martin confirmed scope is smaller than first pass

---

## 1. Why this doc

Per Lumír / Martin's pivot (Discord, 2026-05-05): the conviction-voting `Currency` adapter approach in `pallet-gigahdx-voting` is too risky — a bug there could compromise governance. The pivot keeps voting on plain HDX (no adapter swap) and makes GIGAHDX a non-transferable ticket on the substrate side.

**Update from Martin (13:00 CET):** the current `LockableAToken.sol` works fine with the new design — **no contract rewrite needed**. The only EVM-repo change is moving the substrate-pallet target for the Pool address pointer.

---

## 2. What actually changes in this repo

### 2.1 `contracts/LockableAToken.sol` — NO CHANGE
Confirmed by Martin: the existing implementation (precompile-based free-balance check) works with the new design. The substrate side will keep `GigaHdxVotingLock` storage populated correctly under the new model, so the existing `getLockedBalance` precompile call still returns sensible values.

### 2.2 Pool-address pointer moves from `pallet-liquidation` to `pallet-gigahdx`

Currently, the gigaHdx Pool contract address is registered against `pallet-liquidation.gigaHdxPoolContract`. Martin is moving this storage to `pallet-gigahdx` because that's the more natural owner.

**Affected files in this repo (5 files):**

| File | What needs updating |
|---|---|
| `scripts/lark/set-gigahdx-pool.ts` | The extrinsic call (`api.tx.liquidation.setGigahdxPoolContract(...)`) and 2 query calls (`api.query.liquidation.gigaHdxPoolContract()`) — all → `gigahdx.*`. Plus the file-header comment. |
| `scripts/lark/verify-readiness.ts` | Query at L71 and the human-readable label at L75 (`"pallet_liquidation::gigaHdxPoolContract → sheet.Pool"`) |
| `scripts/lark/test-e2e.ts` | Query at L180 |
| `scripts/lark/test-gigastake-routing.ts` | Query at L95 |
| `docs/gigahdx-deployment.md` | Reference at L17 (`pallet-liquidation update`) — describe the new owner pallet |

**Exact rename (pending Martin's push):**
- `api.query.liquidation.gigaHdxPoolContract` → `api.query.gigahdx.???`
- `api.tx.liquidation.setGigahdxPoolContract` → `api.tx.gigahdx.???`

I'm guessing the new names will be `gigahdx.poolContract` / `gigahdx.setPoolContract` (dropping the redundant `gigaHdx` prefix now that they're on the gigahdx pallet itself). Will confirm once Martin pushes the substrate side and update the scripts in one commit.

### 2.3 Everything else — NO CHANGE
- `markets/gigahdx/index.ts` — same reserve config
- `tasks/proposals/gigahdx-launch.ts` — same proposal flow
- `tasks/misc/deploy-LockableAToken.ts` — same deploy task
- All other `scripts/lark/*` — unchanged
- USDOracleAdapter wiring — unchanged
- HOLLAR facilitator config — unchanged

---

## 3. Lark2 redeploy sequence — tomorrow morning

```
1. Wait for Martin to push the substrate-side pivot
2. Update the 5 files in §2.2 with the new pallet path (one commit)
3. scripts/lark/whitelist-deployer.ts                 (whitelist deployer key)
4. MARKET_NAME=GIGAHDX npx hardhat deploy             (re-deploy pool, configurator, etc.)
5. MARKET_NAME=GIGAHDX npx hardhat deploy-LockableAToken
6. MARKET_NAME=GIGAHDX npx hardhat deploy-FixedPriceOracle --asset stHDX --price 2500000 --network lark2
7. scripts/lark/transfer-admin-to-governance.ts
8. scripts/lark/set-sthdx-oracle.ts
9. scripts/lark/set-gigahdx-pool.ts                   (with the updated pallet path)
10. scripts/lark/submit-gigahdx-proposal.ts
11. scripts/lark/test-e2e.ts                          (with the updated query path)
```

Steps 3–10 are unchanged from today (just step 9 now hits a different pallet).

---

## 4. Things to verify on lark2

| Check | Pass criteria |
|---|---|
| Stake flow | `giga_stake` → user gets GIGAHDX, locked HDX visible in user wallet (substrate detail) |
| Non-transferability of GIGAHDX (per pivot) | substrate-side enforced; ERC20 `transfer` should still revert if `LockableAToken` precompile-based check kicks in correctly under the new lock semantics |
| Liquidation | Treasury liquidation flow succeeds end-to-end (`pallet-liquidation` reads the Pool address from its new home in `pallet-gigahdx`) |
| Read pointer | `api.query.gigahdx.<new-storage-name>()` returns the deployed Pool-Proxy-GIGAHDX address |
| Setter pointer | `api.tx.gigahdx.<new-setter-name>(addr)` accepts and stores the address |

The first two are existing checks unchanged. The last three are the regressions we'd introduce if we forget to migrate one of the 5 files.

---

## 5. Open questions for Martin

1. **Exact storage / extrinsic names**: confirming `gigahdx.poolContract` / `gigahdx.setPoolContract` (or whatever they end up as) once you push.

2. **Is the storage migration in the runtime upgrade?** I.e., does the existing lark2 value at `pallet-liquidation.gigaHdxPoolContract` get auto-migrated, or do we re-run `set-gigahdx-pool.ts` after the upgrade? If migration is in the upgrade, step 9 in §3 becomes a no-op verify rather than an action.

3. **`LockableAToken` deployment**: any reason to redeploy on lark2 even though the bytecode hasn't changed? Default assumption: no — keep the existing artifact, save a deploy step. (Step 5 in §3 can be skipped if the contract is unchanged AND we're not wiping `deployments/lark2/`.)

---

## 6. What I'm NOT touching

- **`hdcl-vault/`** — different workstream, scope clean (Ben's Discord 2026-05-05).
- **HOLLAR repo / GHO contracts** — facilitator wiring is unchanged; bucket capacity stays at 1M.
- **`gigahdx-proposal` PR currently in review** — this pivot lands as a follow-up commit on the same branch (or a follow-up PR), since the diff is small.
- **`LockableAToken.sol`** — confirmed unchanged by Martin.
- **Substrate side** — out of scope for this doc.

---

## 7. Estimated EVM-side effort

Now that the contract rewrite is off the table:

- Update 5 files with new pallet path: 15 min
- Lark2 redeploy + smoke test: 1 hour
- Audit for any other `liquidation.gigaHdx*` references I may have missed: 10 min

**Total: ~1.5 hours.** Most of that is waiting for the lark2 governance vote to enact.
