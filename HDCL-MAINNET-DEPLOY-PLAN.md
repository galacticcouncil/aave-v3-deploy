# HDCL Money Market — Mainnet Deployment Plan

Runbook for deploying the **HDCL Aave V3 market** (a second, isolated Aave
instance: HDCL as supply-only collateral, HOLLAR as the only borrowable via the
GhoAToken facilitator) on **Hydration mainnet**.

This plan is the mainnet projection of the lark-2 rehearsal (see
`hdcl-vault/deployments/lark2.md` and the `lark2` deployment artifacts). lark-2
is a mainnet-state fork, so every step below was executed there first and the
addresses/flow are 1:1 — only the network name (`lark2` → `hydration`),
governance mechanism, and the final addresses change.

> **Principle: reuse mainnet infra.** A second market instance needs its **own**
> `PoolAddressesProvider` + `Pool` + `Configurator` + `ACLManager` + `AaveOracle`,
> but **shares** the main money market's treasury and `PoolAddressesProviderRegistry`.
> Everything that already exists on mainnet (HOLLAR, GhoOracle, ZeroDiscountRateStrategy,
> the treasury, the registry, the aave-manager precompile) is referenced, not redeployed.

---

## 0. Prerequisites (must exist on mainnet before starting)

| Thing | Mainnet address | Notes |
|---|---|---|
| HDCL Vault (proxy) | _deploy first_ | ERC-4626/7540 vault; deploy via `hdcl-vault/script` |
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` | existing |
| GhoOracle ($1 fixed) | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` | existing |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` | existing (hollar mainnet) |
| Main MM treasury (proxy) | `0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9` | **reused** as reserve-factor recipient |
| Main MM PoolAddressesProviderRegistry | `0xEdEcE54767182abc1b04FE699A96CF7e97a3CcF2` | **reused**; owned by aave-manager precompile |
| aave-manager precompile (pool admin) | `0xaa7e0000000000000000000000000000000aa7e0` | governance dispatches as this via `dispatcher.dispatchAsAaveManager` |

All of these are already wired into the HDCL market config for the `hydration`
network (`markets/hdcl/index.ts`, `helpers/constants.ts`).

---

## 1. Deploy the WDCL oracle adapter

The market prices DCL collateral off the vault's `exchangeRate()`. Deploy the
Chainlink-compatible adapter against the **mainnet** vault:

```sh
HARDHAT_NETWORK=hydration npx hardhat deploy-HDCLOracleAdapter --vault <MAINNET_VAULT>
```

Paste the resulting address into `markets/hdcl/index.ts` →
`ChainlinkAggregator[eHydrationNetwork.hydration].DCL`. (The raw `WDCLOracle`
from the vault deploy reads the same rate but only implements the slim
AggregatorV3 surface; the adapter adds the `IEACAggregatorProxy` interface Aave's
oracle infra + MMOracle peg resolver need — deploy the adapter.)

Verify: `cast call <adapter> 'latestAnswer()(int256)'` ≈ `1.00e8` at launch.

---

## 2. Deploy the HDCL Aave market core

```sh
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration npx hardhat deploy --network hydration
```

This deploys: `PoolAddressesProvider-HDCL`, `Pool`, `PoolConfigurator`,
`ACLManager-HDCL`, `AaveOracle-HDCL`, the aToken/debt-token implementations,
rate strategies, `PoolDataProvider-HDCL`. Three things happen automatically
thanks to config baked in during the lark-2 rehearsal:

- **Treasury is reused** — `ReserveFactorTreasuryAddress[hydration]` points at the
  main MM treasury, so `deploy/01_periphery_pre/01_treasury.ts` adopts it instead
  of deploying a new one.
- **Registry is reused** — `EXISTING_PROVIDER_REGISTRY[hydration]` points at the
  main MM registry, so `deploy/00_core/00_markets_registry.ts` adopts it.
  The HDCL provider is **not** registered into it here (registry is
  governance-owned) — that's deferred to the proposal (Phase 5).
- **Reserve init is skipped** — DCL's underlying asset (substrate asset id 550)
  isn't registered yet, so `09_init_reserves.ts` skips it ("defer to governance
  proposal") and `01-after-deploy.ts` skips the reserve-config tasks
  (zero-reserve guard). The market deploys as an empty, admin-owned shell.

The native-token gateway is skipped for the HDCL market (Hydration represents
every token as an ERC20-via-precompile — no native wrap).

Record `Pool-Proxy-HDCL` and `PoolAddressesProvider-HDCL` from
`deployments/hydration/`.

---

## 3. Deploy the 4 GHO/HOLLAR facilitator implementations (hollar repo)

The HOLLAR borrow side uses GHO-style aToken/debt implementations parameterized
for the HDCL pool. These live in **`hollar` (branch `feat/hdcl`)**, not here.

1. Seed `hollar/deployments/hydration/` with the HDCL pool + provider artifacts
   (so `getPool()` / `getPoolAddressesProvider()` resolve), or rely on the
   existing mainnet artifacts.
2. Deploy:
   ```sh
   # in ../hollar (feat/hdcl)
   MARKET_NAME=HDCL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
     npx hardhat deploy --network hydration --tags hdcl_hollar_deploy
   ```
   Produces `GhoAToken-HDCL`, `GhoStableDebtToken-HDCL`,
   `GhoVariableDebtToken-HDCL`, `GhoInterestRateStrategy-HDCL`.
3. Copy those 4 artifacts into `aave-v3-deploy/deployments/hydration/` (the
   proposal task reads them via `hre.deployments.get`).

---

## 4. Deploy the HDCLDepositZap

```sh
HARDHAT_NETWORK=hydration npx hardhat deploy-HDCLDepositZap \
  --hollar 0x531a654d1696ED52e7275A8cede955E82620f99a \
  --vault <MAINNET_VAULT> \
  --pool <Pool-Proxy-HDCL> \
  --precompile 0x0000000000000000000000000000000100000226   # asset 550 (DCL)
```

(The zap atomically does HOLLAR.transferFrom → `vault.deposit(assets, receiver=zap)`
→ `pool.supply` — needed because a substrate batch can't chain the exact mint
amount into `pool.supply`, and `supply` won't accept a sentinel "all".)

---

## 5. Transfer protocol ownership (last step before governance)

Hand the new market's roles to the on-chain admin **before** the governance
proposal — so the proposal can already dispatch as the configured admin.

```sh
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration npx hardhat transfer-protocol-ownership \
  --network hydration
```

Target role-holders on the HDCL ACLManager after this step:

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0xaa7e0000000000000000000000000000000aa7e0` (aave-manager precompile) |
| `POOL_ADMIN` | `0xaa7e0000000000000000000000000000000aa7e0` (precompile) |
| `EMERGENCY_ADMIN` | `0xaa7e0000000000000000000000000000000aa7e0` (precompile — same as PoolAdmin; what the task grants by default) |
| `PoolAddressesProvider-HDCL` owner | `0xaa7e0000000000000000000000000000000aa7e0` (precompile) |

Verify final state before proceeding:

```sh
ACL=<ACLManager-HDCL>
RPC=<mainnet-rpc>
cast call $ACL 'isPoolAdmin(address)(bool)'      0xaa7e0000000000000000000000000000000aa7e0 --rpc-url $RPC  # → true
cast call $ACL 'isEmergencyAdmin(address)(bool)' 0xaa7e0000000000000000000000000000000aa7e0 --rpc-url $RPC  # → true
cast call $ACL 'hasRole(bytes32,address)(bool)' \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  0xaa7e0000000000000000000000000000000aa7e0 --rpc-url $RPC                                                  # → true (DEFAULT_ADMIN)
cast call $ACL 'isPoolAdmin(address)(bool)'      <deployer-eoa> --rpc-url $RPC                              # → false
```

---

## 6. Governance proposal — register asset, init reserves, facilitator

**HDCL launch parameters** (source of truth: `markets/hdcl/reservesConfigs.ts`
in this repo; `helpers/config.ts` in the `hollar` repo):

| Parameter | Value | Source |
|---|---|---|
| DCL `baseLTVAsCollateral` | 8000 (80%) | `reservesConfigs.ts` |
| DCL `liquidationThreshold` | 8500 (85%) | `reservesConfigs.ts` |
| DCL `liquidationBonus` | 10700 (7%) | `reservesConfigs.ts` |
| DCL `liquidationProtocolFee` | 1000 (10%) | `reservesConfigs.ts` |
| DCL `reserveFactor` | 2000 (20%) | `reservesConfigs.ts` |
| DCL `supplyCap` | 3_000_000 | `reservesConfigs.ts` |
| DCL `borrowingEnabled` | false | `reservesConfigs.ts` |
| HOLLAR borrow rate | **10% APY** (= 9.531% APR in ray) | `hollar/helpers/config.ts` (`apyToAprPercent(10)`) |
| HOLLAR facilitator cap | 1_000_000 HOLLAR | `hollar/helpers/config.ts` (`hdclEntityConfig.mintLimit`) |
| HDCL provider id (registry) | 22222255 | `markets/hdcl/index.ts` |

These get baked into the proposal hex by `tasks/proposals/hdcl.ts`. Verify them
in the decoded proposal print-out before submitting.

Generate the proposal preimage:

```sh
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
  npx hardhat hdcl --network hydration
```

The proposal (`tasks/proposals/hdcl.ts`) bundles, as a `utility.batchAll` run as
Root, in the order below. Critical: **the DCL substrate register runs first** —
the substrate→EVM ERC20 precompile needs `decimals()` to resolve, which requires
asset 550 to already be registered before EVM `initReserves(DCL)` is dispatched.
The task hoists this automatically (`txs.unshift`).

1. **Substrate: `assetRegistry.register(550, DCL → vault)`** — must precede #3
2. `AaveOracle-HDCL.setAssetSources(DCL → adapter)`
3. `PoolConfigurator.initReserves([DCL])` — collateral reserve, treasury reused
4. `ReservesSetupHelper.configureReserves(DCL: 80% LTV, 85% liq, 3M supply cap, borrow disabled)`
5. `PoolConfigurator.setLiquidationProtocolFee(DCL, 10%)`
6. **`PoolAddressesProviderRegistry.registerAddressesProvider(HDCL provider, 22222255)`** — into the shared main registry
7. `PoolConfigurator.initReserves([HOLLAR])` — GhoAToken facilitator impls, treasury reused
8. `setReserveBorrowing(HOLLAR, true)`
9. `AaveOracle-HDCL.setAssetSources(HOLLAR → GhoOracle)`
10. `HOLLAR.addFacilitator(GhoAToken proxy, "HDCL", 1M cap)`
11. GHO cross-refs on `GhoAToken-HDCL`: `setVariableDebtToken`, `updateGhoTreasury`
12. GHO cross-refs on `GhoVariableDebtToken-HDCL`: `setAToken`, `updateDiscountRateStrategy`, `updateDiscountToken(HOLLAR)`
13. Substrate: `assetRegistry.register(55, HDCL → DCL aToken proxy)`
14. Substrate: `multiTransactionPayment.addCurrency` (DCL, HDCL as fee currencies)
15. Substrate: `evmAccounts.approveContract(Pool-Proxy-HDCL)` (managed-balance — saves users from per-ERC20 approve before `pool.supply` / `repay`)

All EVM calls are wrapped via `aaveManagerCall` (`dispatcher.dispatchAsAaveManager`,
source = aave-manager precompile). The task prints both the **whitelisted-call
hash** and the **bare batchAll hex** ("Encoded proposal"). Watch the log line
`reordered: DCL substrate register moved <idx> → 0` — that confirms the hoist
fired and the ordering bug is avoided.

### Submitting on mainnet
Per current intent, **not** using the TC-whitelist track. Submit the bare
batchAll on the appropriate OpenGov track and let it run the normal referendum
→ vote → enactment cycle. Idempotency guards in the task mean a re-run after a
partial landing is safe (skips already-registered assets/facilitator/provider).

### Verify after enactment

Wait for the enactment block, then check events + state:

```sh
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
  PROPOSAL_WS=<mainnet-ws> \
  npx hardhat run scripts/verify-hdcl-state.ts --network hydration
```

Every assertion must pass (same expected values as the dry-run section). Then
scan the enactment block's events: every `dispatchAsAaveManager` → `evm.call`
must be `evm.Executed`, **not** `evm.ExecutedFailed` — substrate `evm.call`
returns `Ok` even on internal EVM revert, so the only reliable signal is the
events list.

### Dry-run first (gc chopsticks)
The lark-2 rehearsal confirmed `scripts/submit-hdcl-proposal.ts` works against a
gc chopsticks fork. Same flow for the mainnet dry-run:

```sh
# terminal 1 — gc chopsticks (~/git/chopsticks; needs ../@galacticcouncil/chopsticks-db
# symlinked into node_modules/@acala-network/chopsticks-db until the rebrand is
# pushed through the dist build)
node packages/chopsticks/chopsticks.cjs \
  --config configs/hydradx.yml \
  --endpoint <mainnet-rpc> \
  --port 8000 \
  --db ./hydradx-mainnet.db.sqlite

# terminal 2 — submit + enact in one pass (regenerates the proposal, switches
# chopsticks to Instant block mode, bumps Alice to 5B HDX, votes on Root, scans
# events). PROPOSAL_WS points the script at chopsticks; HARDHAT_NETWORK + RPC
# point ethers/hardhat at the same fork so address resolution matches.
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration RPC=http://localhost:8000 \
  PROPOSAL_WS=ws://localhost:8000 \
  npx hardhat run scripts/submit-hdcl-proposal.ts --network hydration
```

The script (idempotent — safe to re-run after a partial landing):
- Calls `dev_setBlockBuildMode("Instant")` so each tx auto-seals a block (working
  around chopsticks's "Failed to apply inherents" startup error in Instant mode)
- Bumps Alice's free balance to ≥5B HDX via `dev_setStorage` (gc's hydradx.yml
  import-storage truncates her to ~1000 HDX otherwise)
- Submits the batchAll on the Root track, places decision deposit, votes aye with
  full conviction, fast-forwards via `dev_newBlock` until approval + enactment

Inspect the post-enactment events: every `dispatchAsAaveManager` → `evm.call`
must emit `evm.Executed`, not `evm.ExecutedFailed` (substrate `evm.call` returns
`Ok` even on internal EVM revert — **check the events, not the extrinsic result**).
Then run the state verification:

```sh
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration RPC=http://localhost:8000 \
  PROPOSAL_WS=ws://localhost:8000 \
  npx hardhat run scripts/verify-hdcl-state.ts --network hydration
```

Expected output (all ✓):
- 2 reserves: DCL + HOLLAR
- DCL: LTV 8000, liqThreshold 8500, supplyCap 3M, borrowing off, collateral on,
  liqProtocolFee 1000, price ≈ vault exchange rate × 1e8
- HOLLAR: borrowing on, collateral off, price 1e8
- HOLLAR facilitator: label `HDCL`, bucketCapacity 1e24 (1M × 1e18), level 0
- ACL: precompile is PoolAdmin + EmergencyAdmin, deployer is not
- ProviderRegistry: HDCL id 22222255, total providers 2
- Substrate asset 550 (DCL) → vault, Erc20, fee currency
- Substrate asset 55 (HDCL) → aToken proxy, Erc20, fee currency
- `evmAccounts.approvedContract(Pool-Proxy-HDCL)` = true

> Note: `moonbeam-tools fast-execute-chopstick-proposal.ts` (force-enact without
> a vote) is broken as of 2026-05 — `@moonbeam-network/api-augment` doesn't
> resolve against the installed `@polkadot/types`. The submit-and-vote flow
> above replaces it for HDCL.

---

## 7. Flip the UI on

In `hydration-ui` (`feat/hdcl`), set in
`apps/main/src/modules/strategies/hdcl/constants.ts`:

```ts
export const HDCL_HAS_AAVE_LAYER = true
export const HDCL_POOL_ADDRESS         = "<Pool-Proxy-HDCL on mainnet>"
export const HDCL_ATOKEN_ADDRESS       = "<DCL aToken proxy on mainnet>"
export const HDCL_DEPOSIT_ZAP_ADDRESS  = "<HDCLDepositZap on mainnet>"
```

Lark-2 reference values (already committed on `feat/hdcl`):

```ts
HDCL_POOL_ADDRESS         = "0xEAb87D2aAc4C70AF63D2d9E85876665060e117E2"
HDCL_ATOKEN_ADDRESS       = "0x8912ff2164655A3406902ee9e802EBb16ec881D9"
HDCL_DEPOSIT_ZAP_ADDRESS  = "0x146F6C43a0070F42cB532C74c412A34bb55A5729"
```

Borrow / supply-as-collateral / instant-redeem flows are already coded behind
that flag — they light up once it's true.

---

## Asset-id scheme (substrate registry)

| id | name | location target | role |
|---|---|---|---|
| 550 | DCL | vault proxy | pool's underlying reserve asset |
| 55 | HDCL | DCL aToken proxy | user-facing collateral receipt |

Both registered as `Erc20` so the substrate→EVM precompile bridges to the EVM
contract (without it, `pool.supply` / transfers via the precompile see zero
substrate balance and revert).

---

## Lark-2 rehearsal — concrete addresses (reference)

**Status: complete.** HDCL market live on lark-2; governance proposal enacted
via Root referendum #383 at block 222762, parameter patch (LTV/LT 70/80 →
80/85) via #384, rate-strategy revert (10% APR → 10% APY) via #385. UI flipped
on `feat/hdcl` (commit `ab3f64bda`). End-state verified by
`scripts/verify-hdcl-state.ts`; tight-leverage loop converged to 4.99x at
HF 1.0628 with theoretical net APR ≈ 51.83% on equity (vault 18% APY, borrow
9.53% APR).

| Contract | lark-2 address |
|---|---|
| Vault | `0xbDAFEB92440d8696d6C143bc7e6B086d461e3502` |
| HDCLOracleAdapter | `0xAc4C01AbA189d90eCD707938D545f47535843642` |
| PoolAddressesProvider-HDCL | `0x4E75BA5d5EEa7f63F2B43F41913252391Eb3e147` |
| Pool-Proxy-HDCL | `0xEAb87D2aAc4C70AF63D2d9E85876665060e117E2` |
| AaveOracle-HDCL | `0x86c03F1920dE43D3D359487160e1CC1eC44FB319` |
| HDCLDepositZap | `0x146F6C43a0070F42cB532C74c412A34bb55A5729` |
| GhoAToken-HDCL | `0x81d6f4Fe5A2AF0113de51F1c3e8019A731DcF817` |
| GhoStableDebtToken-HDCL | `0x48A87CB6CCE74E356F80846cd90e7de52c7D2e96` |
| GhoVariableDebtToken-HDCL | `0x6E712A053a83De7C3e6261b2d4D3c0886D3C03BD` |
| GhoInterestRateStrategy-HDCL | `0x692F293B6a0486af92e8572C7Ef246cBCCD4Fa0E` |

Mainnet addresses will differ; treasury + registry + HOLLAR + GhoOracle +
ZeroDiscountRateStrategy + aave-manager precompile are identical (mainnet is the
fork source).
