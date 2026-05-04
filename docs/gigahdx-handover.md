# GIGAHDX deployment handover

Operational runbook for taking GIGAHDX from this branch to mainnet. Read end-to-end before starting; some steps depend on coordination with other teams (`gho-core`, `hydration-node`).

---

## TL;DR

GIGAHDX is a second Aave v3 instance on Hydration:
- **Collateral:** stHDX (asset 670, 12 decimals) — only collateral, uses `LockableAToken`
- **Borrow:** HOLLAR (asset 222, 18 decimals) — only borrowable, uses `GhoAToken` facilitator pattern (1M bucket initially)
- **Pool admin:** `0xaa7e0000000000000000000000000000000aa7e0` (Hydration governance EVM precompile)
- **Provider ID:** 22222269

The work is divided across three repos: this one (`aave-v3-deploy`), `gho-core` (HOLLAR-side impls), and `hydration-node` (runtime wiring). All three need to land before the proposal can be enacted.

---

## What this branch contains

- `tasks/proposals/gigahdx-launch.ts` — task that generates the governance proposal preimage. Mirrors the `gigaeth-launch` / `gigasol-launch` shape (normal referendum, not TC fast-track).
- `contracts/LockableAToken.sol` — AToken subclass that blocks transfer/burn of locked balance via `0x0806` precompile.
- `contracts/FixedPriceOracle.sol` — testnet-only mock oracle. Mainnet uses `USDOracleAdapter` at `0x202df3eDac2775b857ee2f61A3569731E53eC713`. The deploy task refuses to run on `HARDHAT_NETWORK=hydration`.
- `markets/gigahdx/` — market config (only `STHDX` reserve; HOLLAR added at proposal time as a separate `initReserves` call).
- `scripts/lark/` — lark2 testnet operational scripts (deploy + admin transfer + per-call referendum submitters + e2e test).
- `scripts/test-mainnet-flow.sh` — local fork verification harness; run this any time you change deploy/launch logic.
- `docs/gigahdx-deployment.md` — original design/planning doc.

---

## Pre-flight checklist (don't skip)

Before any mainnet action:

- [ ] This branch (or `gigahdx-proposal` containing it) has merged to `hydration`.
- [ ] `gho-core` mainnet artifacts are ready: `GhoAToken-GIGAHDX`, `GhoStableDebtToken-GIGAHDX`, `GhoVariableDebtToken-GIGAHDX`, `GhoInterestRateStrategy-GIGAHDX`, `HOLLAR`, `ZeroDiscountRateStrategy`. Confirm with whoever owns `gho-core`.
- [ ] `hydration-node` runtime branch with the GIGAHDX-pool wiring (`AaveMoneyMarket` adapter pointing at the new pool, `pallet-liquidation::liquidate_gigahdx` updated) is merged and a runtime upgrade is scheduled.
- [ ] `LockManager` precompile at `0x0806` is live on mainnet (it backs `LockableAToken.getLockedBalance`).
- [ ] Deployer wallet has HDX for gas (~50 HDX should be plenty for the full deploy).
- [ ] Risk parameters in `markets/gigahdx/reservesConfigs.ts` are signed off:
  - LTV 4000 (40%)
  - Liquidation Threshold 7000 (70%)
  - Liquidation Bonus 10800 (8%)
  - Reserve Factor 2000 (20%)
  - Supply Cap 500_000_000 (12-decimal units, so 500M stHDX)
  - Borrow Cap 0 (collateral-only)
  - Debt Ceiling 0 (HOLLAR facilitator bucket is the cap)
- [ ] HOLLAR facilitator bucket capacity in `tasks/proposals/gigahdx-launch.ts` line 34 (`GIGAHDX_FACILITATOR_BUCKET_CAPACITY = "1000000"`) is the agreed initial value.
- [ ] Local fork test passes: `./scripts/test-mainnet-flow.sh`.

---

## Deployment sequence

### Step 1 — Deploy GIGAHDX core to mainnet

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration \
  npx hardhat deploy --tags market
```

Deploys:
- `PoolAddressesProvider-GIGAHDX`
- `Pool-Proxy-GIGAHDX`
- `PoolConfigurator-Proxy-GIGAHDX`
- `ACLManager-GIGAHDX`
- `AaveOracle-GIGAHDX`
- `PoolDataProvider-GIGAHDX`
- Token impls: `AToken-GIGAHDX`, `DelegationAwareAToken-GIGAHDX`, `StableDebtToken-GIGAHDX`, `VariableDebtToken-GIGAHDX`
- Treasury, IncentivesProxy, EmissionManager
- Reserve rate strategies (DOT, StableOne/Two, VolatileOne)

You'll see this near the end:
```
[init-reserves] SKIP — asset precompile not responsive yet …
```
This is **expected**: stHDX (asset 670) hasn't been registered in the substrate asset registry yet (that happens inside the proposal). The deploy correctly defers reserve init.

**Verify on Blockscout:**
- `PoolAddressesProvider-GIGAHDX` is registered in `PoolAddressesProviderRegistry` (`0xEdEcE54767182abc1b04FE699A96CF7e97a3CcF2`) with provider id `22222269`.
- All deploy txs show `Success`.

**Commit the artifacts:**
```bash
git add deployments/hydration/*-GIGAHDX.json deployments/hydration/.migrations.json
git commit -m "deploy GIGAHDX core to mainnet"
```

### Step 2 — Deploy LockableAToken

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration \
  npx hardhat deploy-LockableAToken
```

One contract: `LockableAToken-GIGAHDX`. It reads `Pool-Proxy-GIGAHDX` from step 1, so step 1 must come first.

```bash
git add deployments/hydration/LockableAToken-GIGAHDX.json
git commit -m "deploy LockableAToken-GIGAHDX"
```

### Step 3 — Deploy GHO impls (in `gho-core` repo)

Coordinate with `gho-core` owner:
```bash
# in gho-core/
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration \
  npx hardhat deploy --tags gigahdx_gho_deploy
```

Then copy 6 artifacts back into this repo:
```bash
GHO=../gho-core/deployments/hydration
cp $GHO/GhoAToken-GIGAHDX.json \
   $GHO/GhoStableDebtToken-GIGAHDX.json \
   $GHO/GhoVariableDebtToken-GIGAHDX.json \
   $GHO/GhoInterestRateStrategy-GIGAHDX.json \
   $GHO/HOLLAR.json \
   $GHO/ZeroDiscountRateStrategy.json \
   deployments/hydration/

git add deployments/hydration/{GhoAToken,GhoStableDebtToken,GhoVariableDebtToken,GhoInterestRateStrategy}-GIGAHDX.json \
        deployments/hydration/HOLLAR.json \
        deployments/hydration/ZeroDiscountRateStrategy.json
git commit -m "import GHO impls for GIGAHDX from gho-core"
```

`HOLLAR.json` should contain the existing mainnet GhoToken's ABI/address (`0x531a654d1696ED52e7275A8cede955E82620f99a`); confirm this is the case before committing.

### Step 4 — Transfer admin roles to governance

The deploys above used your EOA as admin. Move all admin roles to `0xaa7e…` so the proposal's `dispatcher.dispatchAsAaveManager` calls satisfy ACL checks:

```bash
HARDHAT_NETWORK=hydration npx hardhat run scripts/lark/transfer-admin-to-governance.ts
```

(The script lives under `scripts/lark/` for historical reasons but is safe on mainnet — it explicitly targets `0xaa7e0000000000000000000000000000000aa7e0`.)

What it does:
- `ACLManager-GIGAHDX`: grants `DEFAULT_ADMIN_ROLE`, `POOL_ADMIN`, `RISK_ADMIN`, `EMERGENCY_ADMIN` to gov.
- `PoolAddressesProvider-GIGAHDX`: `setACLAdmin(gov)` and `transferOwnership(gov)`.

After this you can no longer admin GIGAHDX from your EOA. **Don't re-run any admin-mutating script on the deployer key after this point.**

### Step 5 — Generate proposal preimage

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration \
  npx hardhat gigahdx-launch
```

Output:
```
submit preimages: 0x…   ← preimage hex (this is what you submit)
<decoded tree>          ← human-readable view of every call in the batchAll
```

**Inspect the tree carefully.** Verify each line:
1. `evm.call(setAssetSources([stHDX], [USDOracleAdapter])` on `AaveOracle-GIGAHDX`
2. `evm.call(initReserves([stHDX]))` with LockableAToken impl
3. `evm.call(addRiskAdmin(ReservesSetupHelper))`
4. `evm.call(configureReserves(stHDX risk params))`
5. `evm.call(setLiquidationProtocolFee(stHDX, 1000))`
6. `evm.call(reviewReserveFactors)` updates if needed
7. `evm.call(initReserves([HOLLAR]))` with GhoAToken impl
8. `evm.call(setReserveBorrowing(HOLLAR, true))`
9. `evm.call(setAssetSources([HOLLAR], [GhoOracle]))` (`$1` fixed)
10. `evm.call(addFacilitator(GhoAToken proxy, "GIGAHDX", 1M))` on HOLLAR
11. `evm.call(setVariableDebtToken/setAToken/updateGhoTreasury/updateDiscountRateStrategy/updateDiscountToken)` cross-refs
12. `assetRegistry.register(670, "stHDX", …)` if not already registered
13. `assetRegistry.register(67, "GIGAHDX", …)` pointing at the predicted aToken address

**Critical check on items 10/11:** the GhoAToken proxy address is predicted from `getContractAddress({from: PoolConfigurator, nonce: ...})`. The task computes this assuming a clean execution. If the on-chain configurator nonce moved between proposal generation and submission, the prediction is wrong and the proposal will brick mid-batch. Re-generate the preimage close to submission time.

### Step 6 — Submit + vote

Submit via Hydration governance UI (or Polkadot.js). High-level flow:
1. `preimage.notePreimage(0x…)` — notes the preimage on-chain.
2. `referenda.submit({Origins: ?}, {Lookup: {hash, len}}, {After: 1})` — track depends on what gigaETH/gigaSOL used; typically `Root` for parameters this consequential.
3. `referenda.placeDecisionDeposit(refIndex)` — deposit lock.
4. Open forum post with preimage hash and decoded tree for community.
5. Wait for stake-weighted vote and decision period.

### Step 7 — Wait for enactment

When the referendum passes and enactment fires, every call in the preimage runs as an atomic `batchAll`. If any call fails, the whole batch reverts.

After enactment, verify:
- `Pool-Proxy-GIGAHDX.getReservesList()` returns `[stHDX, HOLLAR]`.
- `AaveOracle-GIGAHDX.getAssetPrice(stHDX)` returns a non-zero number.
- `AaveOracle-GIGAHDX.getAssetPrice(HOLLAR) == 1e8`.
- `HOLLAR.getFacilitator(GhoAToken proxy)` returns `bucketCapacity = 1_000_000e18`.
- `assetRegistry.assets(67)` and `assetRegistry.assets(670)` are both `Some(...)`.

### Step 8 — Runtime wiring

Coordinate with `hydration-node`:
- `AaveMoneyMarket` adapter must point at `Pool-Proxy-GIGAHDX` (not the existing Hydration MM pool).
- `pallet-liquidation::liquidate_gigahdx` must target the same pool.

Either a separate gov extrinsic or part of the next runtime upgrade. Until this is in place, `giga_stake` calls will fail or route to the wrong pool.

### Step 9 — Smoke test

End-to-end on mainnet:
1. **Supply path:** Substrate `giga_stake(HDX)` → expect stHDX → MM supply → mint GIGAHDX (asset 67).
2. **Borrow path:** EVM `pool.borrow(HOLLAR, amount, 2, 0, user)` from a stHDX-collateralized account.
3. **Repay path:** `pool.repay(HOLLAR, …)` → confirm bucket level decreases.
4. **Withdraw path:** burn GIGAHDX → withdraw stHDX → unstake to HDX.
5. **Vote-and-liquidate path:** `giga_stake` → vote with conviction → confirm `LockableAToken._transfer` blocks moving locked balance → expire vote lock → confirm balance transferable.
6. **Existing Hydration MM** is unaffected — supply/borrow on USDC/USDT/DOT/etc. still works.

If the bucket fills faster than expected, raise the cap via a follow-up gov proposal calling `HOLLAR.setFacilitatorBucketCapacity(GhoAToken, newCap)`.

---

## Reference

### Key addresses (mainnet)

| | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle ($1 fixed) | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| HDX/USD oracle (DIA) | `0xea63e594ee00590938E856F2134E6C792bA92d13` |
| stHDX `USDOracleAdapter` | `0x202df3eDac2775b857ee2f61A3569731E53eC713` |
| Existing Hydration MM Pool | `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38` |
| `PoolAddressesProviderRegistry` | `0xEdEcE54767182abc1b04FE699A96CF7e97a3CcF2` |
| Hydration gov EVM precompile | `0xaa7e0000000000000000000000000000000aa7e0` |
| `LockManager` precompile | `0x0000000000000000000000000000000000000806` |

### Substrate asset IDs

| Asset | ID | Decimals | Notes |
|---|---|---|---|
| HDX | 0 | 12 | native |
| HOLLAR | 222 | 18 | already registered |
| stHDX | 670 | 12 | registered by the proposal |
| GIGAHDX | 67 | 12 | aToken receipt; registered by the proposal pointing at the LockableAToken address |

### HOLLAR facilitator allocations (for context)

| Facilitator | Bucket |
|---|---|
| Hydration Market (existing) | 7M |
| Flash Minter | 100K |
| HSM | 18M |
| **GIGAHDX (new)** | **1M** ← starts here, raise via proposal as needed |

### How the stHDX price resolves on mainnet

```
AaveOracle-GIGAHDX.getAssetPrice(stHDX)
  → USDOracleAdapter (0x202df…)
    → assetToX:  Hydration EMA precompile (10-min TWAP) — stHDX/HDX from `gigahdxs` source
    → xToUSD:    DIA HDX/USD chainlink oracle
  → returns 8-decimal USD price
```

Lark testnets use `FixedPriceOracle` instead because the EMA precompile isn't populated. The deploy-time guard prevents that mock from ever landing on mainnet (`tasks/misc/deploy-FixedPriceOracle.ts` throws on `network.name === "hydration"`).

---

## Local testing

Before any change to deploy logic or the launch task, run the harness:
```bash
./scripts/test-mainnet-flow.sh
```

Coverage:
- Forks Hydration mainnet locally.
- Runs steps 1–4 end-to-end.
- Generates the first ~5 batched txs of the proposal (the rest is environmental — see "Known limits" below).
- Verifies the FixedPriceOracle mainnet guard fires.

For full proposal-execution coverage, use the lark2 path (Alice as sole TC member, fast referendum):
```bash
# scripts/lark/README.md has the full lark2 sequence
ts-node scripts/lark/test-e2e.ts
```

### Known limits of local fork testing

- `tasks/misc/review-reserve-factors.ts` (and similar review tasks) read addresses from `deployments/${FORK || network.name}/`. With `FORK=hydration HARDHAT_NETWORK=localhost`, that resolves to `deployments/hydration/` — which only has accurate addresses *after* you've actually done step 1 on mainnet. So a fresh fork test can't fully exercise step 5; the lark2 path covers this gap.
- The runtime side (steps 8/9) cannot be tested without a substrate fork. Lark2 has the runtime changes deployed for testing.
- `markets/zombie/reservesConfigs.ts` has a duplicate `strategySTHDX` that surfaces in `tsc --noEmit`. Pre-existing; not a regression. Don't fix in this PR.
- `markets/hydration/index.ts:73` has `WETH` commented out of `ReserveAssets` while still in `ReservesConfig`. Blocks any future Hydration MM redeploy. Pre-existing; out of scope.

---

## Troubleshooting

### "not pool admin: 0xaa7e…"
The launch task's `aclManager.isPoolAdmin(admin)` precondition fired. You haven't run step 4 (transfer admin) yet, or it failed silently. Re-run step 4 and verify by calling `aclManager.isPoolAdmin("0xaa7e0000000000000000000000000000000aa7e0")` directly.

### "RESERVE_ALREADY_INITIALIZED"
Someone (you, on a previous attempt, or a partial enactment) already initialized stHDX or HOLLAR. The launch task has idempotency guards for HOLLAR (`_hollarAlreadyInit`) and stHDX (`sthdxAlreadyInit`); they should detect this and skip. If the guards fail, the predicted nonces in the proposal won't match — re-generate the preimage from the current chain state.

### "FACILITATOR_ALREADY_EXISTS"
The launch task guards against this too (it checks `bucketCapacity > 0` before adding). If it triggers anyway, someone added the facilitator out-of-band — investigate before re-submitting.

### Predicted GhoAToken address ≠ actual deployed address after enactment
The configurator nonce moved between proposal generation and submission. Re-generate the preimage close to submission time. If you can't, you'll need a follow-up proposal to fix the cross-references (`setVariableDebtToken`, `setAToken`, etc.).

### "INVALID_CHAIN_ID" on `deploy-FixedPriceOracle`
You're targeting a network without a chainId set. Add it to `hardhat.config.ts` or use a network that already has one (`localhost` or `lark2`).

### "Refusing to deploy FixedPriceOracle on hydration mainnet"
Working as designed. If you really need a mock oracle on mainnet (you don't), use the prod `USDOracleAdapter` instead. The error message points at the right address.

---

## Rollback / partial-failure handling

`batchAll` is atomic: any single call failing reverts everything. So a partial-state mainnet is unlikely from this proposal alone. But:

- **Before submission:** abandon the preimage. Nothing to undo.
- **After noting preimage but before enactment:** the preimage just sits there; expires after some retention period. No action needed.
- **If enactment partially fails (shouldn't with `batchAll`):** the runtime would revert; nothing to undo. Investigate the cause, fix, re-submit.
- **If enactment succeeds but reveals a parameter mistake:** submit a follow-up proposal to fix (e.g., raising bucket cap, changing reserve factor). The PoolAdmin role is now governance, so all corrections go through the same channel.

The contracts deployed in steps 1–3 cannot be cleanly undone — the `PoolAddressesProvider-GIGAHDX` is registered in the registry, the GIGAHDX provider id is taken, and the addresses are immortal. If the launch is canceled mid-flight, those contracts just sit unused. The next launch attempt would either reuse them or pick a new provider id.

---

## Out-of-scope follow-ups

These are visible from this branch but should NOT be touched in this PR:

- **`markets/zombie/`** — redundant test market. Audit and delete (or migrate test usages) in a separate PR.
- **`markets/hydration/index.ts:73`** — WETH commented out of `ReserveAssets`. Fix before any future Hydration MM redeploy.
- **`scripts/lark/transfer-admin-to-governance.ts`** — works for mainnet too despite the path; consider moving to `scripts/` (top-level) and renaming, separate PR.
- **HDCL Vault** (`hdcl-vault/` directory) — separate workstream with its own review/PR. The 15 issues from the prior line-by-line review (oracle decimals, missing storage gap, etc.) are tracked elsewhere.

---

## Contacts

- Hydration governance: forum + Polkadot.js for proposal submission.
- `gho-core` artifacts: confirm with the team that owns that repo.
- `hydration-node` runtime: confirm the GIGAHDX wiring branch and runtime upgrade schedule.

If anything in this doc is out of date, update it in the same commit as the change that made it stale.
