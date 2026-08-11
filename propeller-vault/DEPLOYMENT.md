# Propeller Deployment Runbook

> Audience: deploy operator / Hydration governance facilitator
> Companion to: `script/*.s.sol`, `tasks/proposals/propeller.ts`, `scripts/propeller/verify-readiness.ts`,
> `deployments/`, and `../PROPELLER-MAINNET-HANDOVER.md` (read the "What went wrong" section first)

The Foundry scripts handle the **on-chain contract deploy**. Everything else — listing the
synthetic reserve, wiring the contracts, delegating the guardian, starting the keeper — is
governance and operations, and is the part that has historically gone wrong.

**The single most important thing on this page:** `dispatcher.dispatchAsAaveManager` reports
EVM reverts as `ExecutedFailed` *events*, not as extrinsic failures. A wiring referendum can
enact "successfully" with individual calls silently reverted. Never trust the referendum
result — run `verify-readiness.ts` and read its table.

---

## Step 0 — Pre-flight

| Item | Where | Sanity check |
|---|---|---|
| Deployer is a whitelisted contract deployer | `evmAccounts.contractDeployer` | Must be in the whitelist or every `forge script` reverts |
| Deployer funded | any | Needs the EVM gas token, not just HDX |
| `POOL`, `HOLLAR`, `HOLLAR_VDEBT`, `ETH`/`TBTC`, `AETH`/`ATBTC`, `PRIME`, `APRIME` | `.env` | Read live off `pool.getReserveData` — do **not** trust a previous lark's values |
| Synthetic asset id is free | `assetRegistry.assets(5550)` | Must be `None`, else pick another and set `PROPELLER_SYNTH_ASSET_ID` |
| Router pallet index is 66/67 | `scripts/propeller/gen-router-reference.mjs` | **Run this.** `DcaDispatch` bakes pallet 67 into SubLoop's bytecode; a runtime reorder breaks every deposit and unwind and needs a UUPS upgrade to fix |
| Router has a PRIME→collateral route | router | `compound` cannot convert carry without it |
| HydraAugustus (REQ-SWAP) deployed | `../aave-debt-swap` | Not on mainnet yet. Without it `compound` is inert — deploy with the placeholder and `setSwapper` later |
| pool-143 depth vs `dcaSlippagePpm` | stableswap | Thin depth forces a wider min-out; see the handover doc's lark-4 lesson |

---

## Step 1 — Deploy the contracts

Order matters — each step consumes the previous one's output.

```sh
cd propeller-vault
cp .env.lark4.example .env      # fill in the [chain] values
FLAGS="--rpc-url $RPC --broadcast --evm-version london --legacy --slow --gas-estimate-multiplier 200"

forge script script/DeploySynth.s.sol:DeploySynth       $FLAGS   # → SYNTH
forge script script/DeployMain.s.sol:DeployMain         $FLAGS   # → SUBLOOP, VAULT_ETH, HARVESTER, IMPL
forge script script/DeployVaultTBTC.s.sol:DeployVaultTBTC $FLAGS # → VAULT_TBTC   (optional)
```

`DeployMain` also emits the `CollateralVault` implementation address — record it; `DeployVaultTBTC`
reuses it rather than redeploying.

**What `initialize` does automatically:**
- Grants `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `UPGRADER_ROLE` **and** `GUARDIAN_ROLE` to `_admin`
  (the governance precompile), so the pause is never wired to a role nobody holds.
- Sets `tvlCap`, `targetHf`, `deLeverTrigger`, `deployHfFloor = targetHf`, `harvestThreshold`.

**What it deliberately does NOT do — every one of these fails closed until Step 2:**

| Unset | Consequence until wired |
|---|---|
| synthetic reserve not listed | `synthLtBps()` reverts `SynthReserveNotListed` ⇒ **every `deposit` reverts** |
| `SubLoop.harvester` | `harvest()` reverts `HarvesterUnset` ⇒ no carry realisation |
| `compoundSlippageBps` (0) | the compound floor equals the exact oracle price ⇒ **every `compound` reverts** |
| route ids (0) | `pokeBorrow`/`pokeRepay` dispatch a malformed call ⇒ `DispatchFailed` |
| `deployTranche`/`unwindTranche` (0) | tranche caps disabled ⇒ one `pokeBorrow` dumps the whole borrow into pool-143 |
| `VAULT_ROLE` | `SubLoop.deposit` reverts ⇒ deposits revert |
| `MINTER_ROLE` | `SyntheticToken.mint` reverts ⇒ deposits revert |

This is intentional: an unwired deployment is inert rather than exploitable.

---

## Step 2 — Governance wiring

```sh
cd ..   # repo root
PROPELLER_SYNTH=0x… PROPELLER_SUBLOOP=0x… PROPELLER_HARVESTER=0x… \
PROPELLER_VAULTS=0xETH,0xTBTC PROPELLER_SWAPPER=0x… PROPELLER_GUARDIAN=0x… \
npx hardhat propeller --network hydration
```

This prints **four** preimages. Submit each as its own Root referendum, **in order**:

0. **`compound routes`** — `router.forceInsertRoute` for PRIME → each collateral.
   `Harvester.harvest` calls `compound(prime, cut, minOut, "")` with an **empty**
   route, so the substrate router resolves the path from its own storage and falls back
   to Omnipool when nothing is stored. PRIME is not an Omnipool asset, so without this
   **every harvest reverts** and loop carry can never reach the vaults. Pure substrate —
   no contracts needed, so it can enact before anything else.
1. **`list-reserve`** — registers the synthetic as an `Erc20` substrate asset, then
   `initReserves`. The substrate registration MUST come first: the EVM ERC20 precompile reads
   decimals from the registry, so `initReserves` reverts otherwise.
2. **`configure`** — `configureReserveAsCollateral(LTV 100, LT 9800, bonus 10100)`,
   `setReserveBorrowing(false)`, `setSupplyCap(0)`, `setAssetSources($1 oracle)`.
3. **`wire`** — `MINTER_ROLE` → each vault, `registerVault`, `setTranches`, `configureDca`,
   `setHarvester`, `setCompoundSlippageBps`, `setSwapper`, `addVault`, and
   `GUARDIAN_ROLE` → technical committee.

They are split because `initReserves` alone is ~58e9 refTime and a combined `batchAll` trips
`scheduler.PermanentlyOverweight` (observed on lark-2).

> **LT 9800 is not a deploy parameter.** The vault reads the synthetic's liquidation threshold
> live off this reserve's config bitmap on every deposit, rebalance and peg top-up. Batch 2 is
> the only place it is set, and changing it later changes the floor for every existing position.

---

## Step 3 — Verify before doing anything else

```sh
PROPELLER_SYNTH=0x… PROPELLER_SUBLOOP=0x… PROPELLER_HARVESTER=0x… \
PROPELLER_VAULTS=0xETH,0xTBTC PROPELLER_SWAPPER=0x… PROPELLER_GUARDIAN=0x… \
PROPELLER_LOOPER=0x… \
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
  scripts/propeller/verify-readiness.ts
```

Read-only, exits non-zero on any failure. **Do not proceed past a red row.** It checks the
runtime pallet indices, the substrate registration, bytecode presence, every bit of the
synthetic reserve config, every role, every wiring value, per-vault live state, loop health,
and keeper funding.

---

## Step 4 — Seed and ramp

```sh
# 1. small seed deposit (establishes the share price; DEAD_SHARES = 1000 wei are burned)
node scripts/propeller-deposit-lark.mjs

# 2. ramp the loop — REQUIRED before anyone can redeem
node scripts/propeller-ramp-lark.mjs
```

**The ramp is not optional.** PRIME is an isolation-mode reserve, so a plain supply never
auto-enables it as collateral — only `pokeBorrow`'s explicit
`setUserUseReserveAsCollateral` does. Until it runs, `totalEquity()` is 0 and
`requestRedeem` reverts `NoLoopEquity` (it used to silently escrow shares against a zero
unwind target and orphan the request — see the handover doc).

Sanity after ramping:
- `subLoop.healthFactor()` ≈ `targetHf` (1.05), not far above it
- `subLoop.totalEquity() > 0`
- `vault.exchangeRate()` ≈ 1e18
- a `requestRedeem` → `pokeRepay` → `pokeSettle` → `claim` round-trip completes

---

## Step 5 — Start the keeper

```sh
export SUBLOOP_ADDRESS=0x… VAULT_ADDRESS=0x… HARVESTER_ADDRESS=0x…
export LOOPER_PRIVATE_KEY=0x… ALERT_WEBHOOK=https://discord.com/api/webhooks/…
docker stack deploy -c propeller-vault/looper/docker-stack.yml propeller-looper
```

`replicas` MUST stay 1 — two loopers fight over the signer's nonce every cycle. The key needs
**no role**: every poke is permissionless, so it only pays gas.

---

## Rollback / abort paths

| Scenario | Action |
|---|---|
| Batch 1 enacts but batch 2 fails | Reserve is listed but unconfigured. `deposit` reverts (`SynthReserveNotListed` → LT 0). Re-submit batch 2; nothing is stuck |
| Batch 3 partially reverts | Most likely cause. `verify-readiness` names the exact missing call — re-submit just that one as its own referendum |
| Deposits revert `SynthReserveNotListed` | Batch 2's `configureReserveAsCollateral` did not land. Check LT with `pool.getConfiguration(synth) >> 16 & 0xFFFF` |
| Deposits revert `DcaDispatch.DispatchFailed` | Route ids wrong, `dcaSlippagePpm` too tight for pool depth, or the router pallet moved. Run `gen-router-reference.mjs` first, then widen slippage |
| `compound` always reverts | `compoundSlippageBps` is 0, `swapper` is still the placeholder, or batch 0's PRIME → collateral route is missing (the empty-route path resolves on-chain) |
| `harvest` reverts on the swap leg | Batch 0 did not land. Check `router.routes({assetIn: PRIME, assetOut: collateral})` is `Some` |
| `harvest` reverts `HarvesterUnset` | `setHarvester` did not land |
| `harvest` reverts "vault set incomplete" | A share-holding vault is missing from `Harvester.addVault`, or one is registered twice |
| Wrong yield source wired | `setYieldSource` works **only before the first deposit** — `DEAD_SHARES` keep `loopShares` permanently non-zero afterwards. After that, redeploy the vault |
| Emergency | `pause()` (guardian) stops deposits, new redemptions, rebalance and compound. `pokeSettle`/`claim` stay live so in-flight settlement completes. There is no admin force-unwind |

---

## Post-deploy invariants to confirm before announcing

1. `verify-readiness.ts` exits 0.
2. A full deposit → ramp → requestRedeem → pokeRepay → pokeSettle → claim round-trip completes
   and returns ≥ the deposited collateral.
3. `harvest` → `compound` raises `exchangeRate()` without minting shares.
4. `subLoop.negativeCarryBps() == 0`.
5. Keeper runs ≥ 3 consecutive cycles with no errors.
6. Update `deployments/` with the addresses, roles and on-chain state — that file is what the
   UI and integrator teams read.
