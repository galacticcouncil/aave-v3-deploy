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

## 5. Governance proposal — register asset, init reserves, facilitator

Generate the proposal preimage:

```sh
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
  npx hardhat hdcl --network hydration
```

The proposal (`tasks/proposals/hdcl.ts`) bundles, as a `utility.batchAll` run as
Root, in order:

1. `AaveOracle-HDCL.setAssetSources(DCL → adapter)`
2. `PoolConfigurator.initReserves([DCL])` — collateral reserve, treasury reused
3. `ReservesSetupHelper.configureReserves(DCL: 70% LTV, 80% liq, 3M supply cap, borrow disabled)`
4. `PoolConfigurator.setLiquidationProtocolFee(DCL, 10%)`
5. **`PoolAddressesProviderRegistry.registerAddressesProvider(HDCL provider, 22222255)`** — into the shared main registry
6. `PoolConfigurator.initReserves([HOLLAR])` — GhoAToken facilitator impls, treasury reused
7. `setReserveBorrowing(HOLLAR, true)`
8. `AaveOracle-HDCL.setAssetSources(HOLLAR → GhoOracle)`
9. `HOLLAR.addFacilitator(GhoAToken proxy, "HDCL", 1M cap)`
10. GHO cross-refs (`setVariableDebtToken`, `updateGhoTreasury`, `setAToken`, `updateDiscountRateStrategy`)
11. Substrate: `assetRegistry.register/update` DCL (550 → vault) + HDCL (55 → aToken)
12. Substrate: `multiTransactionPayment.addCurrency` (DCL, HDCL as fee currencies)
13. Substrate: `evmAccounts.approveContract(Pool-Proxy-HDCL)` (managed-balance, no ERC-20 approve needed)

All EVM calls are wrapped via `aaveManagerCall` (`dispatcher.dispatchAsAaveManager`,
source = aave-manager precompile). The task prints both the **whitelisted-call
hash** and the **bare batchAll hex** ("Encoded proposal").

### Submitting on mainnet
Per current intent, **not** using the TC-whitelist track. Submit the bare
batchAll on the appropriate OpenGov track and let it run the normal referendum
→ vote → enactment cycle. Idempotency guards in the task mean a re-run after a
partial landing is safe (skips already-registered assets/facilitator/provider).

### Dry-run first (chopsticks)
Fork mainnet with the gc chopsticks config and force-enact without a real vote:

```sh
# terminal 1 — gc chopsticks (~/git/chopsticks, branch gc; EVM-capable, mock-signature)
yarn start --config configs/hydradx.yml --endpoint <mainnet-rpc> --port 8000

# terminal 2 — fast-execute the bare batchAll (moonbeam-tools, branch hydration)
bun src/tools/fast-execute-chopstick-proposal.ts --url ws://127.0.0.1:8000 \
  --encoded-proposal "$(cat batchall.hex)"
```

This submits a Root referendum then overrides referendum + scheduler storage via
`dev_setStorage`/`dev_newBlock` to enact in the next block — no deposit/vote/
balance needed. Inspect the post-enactment events: every `dispatchAsAaveManager`
→ `evm.call` must succeed (substrate `evm.call` returns `Ok` even on internal
EVM revert and emits `evm.ExecutedFailed`, so check the **events**, not the
extrinsic result).

> ⚠️ Known snag (2026-05): `moonbeam-tools` imports `@moonbeam-network/api-augment`
> across many modules, which fails to resolve against the installed
> `@polkadot/types`. `fast-execute-chopstick-proposal.ts` was patched to import
> `getApiFor`/`NETWORK_YARGS_OPTIONS` from `../utils/networks.ts` directly, but
> `networks.ts` → `moonbeam-types-bundle` still drags it in. Resolve the augment
> version (or stub the package) before relying on the chopsticks dry-run.

---

## 6. Flip the UI on

In `hydration-ui` (`feat/hdcl`), set in `modules/strategies/hdcl/constants.ts`:

```ts
export const HDCL_HAS_AAVE_LAYER = true
export const HDCL_POOL_ADDRESS = "<Pool-Proxy-HDCL>"
export const HDCL_ATOKEN_ADDRESS = "<DCL aToken proxy>"
export const HDCL_DEPOSIT_ZAP_ADDRESS = "<HDCLDepositZap>"
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
