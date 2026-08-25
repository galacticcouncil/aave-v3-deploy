# BIL Money Market — Mainnet Deployment Plan

Runbook for deploying the **BIL Aave V3 market** (a second, isolated Aave
instance: BIL as supply-only collateral, HOLLAR as the only borrowable via the
GhoAToken facilitator) on **Hydration mainnet**.

This plan is the mainnet projection of the lark-2 rehearsal (see
`bil-vault/deployments/lark2.md` and the `lark2` deployment artifacts). lark-2
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
| BIL Vault (proxy) | _Step 0a below_ | ERC-4626/7540 vault — deploy first |
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` | existing |
| GhoOracle ($1 fixed) | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` | existing |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` | existing (hollar mainnet) |
| Main MM treasury (proxy) | `0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9` | **reused** as reserve-factor recipient |
| Main MM PoolAddressesProviderRegistry | `0xEdEcE54767182abc1b04FE699A96CF7e97a3CcF2` | **reused**; owned by aave-manager precompile |
| aave-manager precompile (pool admin) | `0xaa7e0000000000000000000000000000000aa7e0` | governance dispatches as this via `dispatcher.dispatchAsAaveManager` |

All of these are already wired into the BIL market config for the `hydration`
network (`markets/bil/index.ts`, `helpers/constants.ts`).

---

## 0a. Deploy the BIL Vault

The vault is the foundation — every later phase keys off the vault proxy
address. Dry-run against a chopsticks mainnet fork first, then broadcast
the same flow against real mainnet.

### Dry-run against a chopsticks mainnet fork

```sh
# terminal 1 — chopsticks against mainnet
cd ~/git/chopsticks
node packages/chopsticks/chopsticks.cjs --config configs/hydradx-mainnet.yml --port 8000

# terminal 2 — flip Instant, fund a test EVM deployer, dry-run the deploy
curl -sX POST http://localhost:8000 -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"dev_setBlockBuildMode","params":["Instant"]}'
node scripts/fund-test-deployer.mjs                # fund hardhat dev #0 with WETH
node scripts/deploy-bil-vault.mjs               # ports Deploy.s.sol to viem
```

The dry-run prints the addresses + verifies `getOraclePrice() > 0` and
`exchangeRate() ≈ 1e18`. Typical output:

```
1. QueueLib:        0xcf7ed3a…  gasUsed 807,396
2. BILVault impl:  0xdc64a14…  gasUsed 9,064,722
3. ERC1967Proxy:    0x5fc8d32…  gasUsed 839,238
4. BILOracle:      0x0165878…  gasUsed 374,784
5. setOracle:                   gasUsed 61,326
6. getOraclePrice = 1.0e18  ✅
```

Total ~11.15M gas. At mainnet `eth_gasPrice ≈ 3.78M wei`: ≈ **0.042 WETH**;
budget ~0.1 WETH for headroom.

### Findings from the dry-run (apply to mainnet broadcast)

These bit the dry-run and will bite a mainnet run the same way unless
handled — they aren't in `Deploy.s.sol` because the lark deploy script
ran against lark testnet where the constraints are looser:

1. **Hydration's pallet-ethereum rejects EIP-1559 (type-2) txs** (`custom:2`).
   Use legacy (type-0) txs. `forge --legacy` does this; the viem deploy
   script sets `type: "legacy"` + `gasPrice` (not maxFee/maxPriorityFee).
2. **`gasPrice` must be ≥ live `eth_gasPrice`.** Mainnet's DynamicEvmFee
   sits at ~3.78M wei (vs ~1.5M on lark testnets). Query at runtime; don't
   hard-code lark's value.
3. **Per-tx gas cap is ~12M.** 18M fails validate (`custom:13` = gas
   exceeds limit). The vault impl needs ~9M; size your txOpts accordingly.
4. **`forge script ... --broadcast --rpc-url http://chopsticks` mis-handles
   chopsticks's lazy-loaded delegatecall state.** Internal staticcalls
   through proxies return `[Stop]` even when `cast call` to the same
   selector works. The viem script (`deploy-bil-vault.mjs`) bypasses
   this entirely. For the **mainnet broadcast** you can use forge directly
   (no lazy-loaded state involved) OR the viem script — both work; the
   viem script is what was end-to-end validated above.

### Mainnet broadcast

After the dry-run succeeds, broadcast with operator's mainnet key:

```sh
# Option A — viem script (validated path; legacy txs handled, gasPrice queried)
RPC=https://rpc.hydradx.cloud \
  PRIVATE_KEY=0x<mainnet-deployer-key> \
  node scripts/deploy-bil-vault.mjs
# (despite the name, the script broadcasts wherever RPC points)

# Option B — forge against mainnet directly (Deploy.s.sol; constants are
# already mainnet)
cd ~/git/aave-v3-deploy/bil-vault
ADMIN_ADDRESS=0x<deployer-eoa> \
PRIVATE_KEY=0x<mainnet-deployer-key> \
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://rpc.hydradx.cloud \
  --broadcast --legacy --slow --gas-estimate-multiplier 200
```

Record the proxy address. That's `MAINNET_VAULT` for the rest of the plan.

### Post-deploy — grants + seed + role rotation

```sh
RPC=https://rpc.hydradx.cloud \
  PRIVATE_KEY=0x<deployer> \
  VAULT_ADDRESS=<MAINNET_VAULT> \
  GUARDIAN_ADDRESS=<hydration-tech-committee> \
  KEEPER_ADDRESS=<keeper-bot> \
  SEED_AMOUNT=100 \
  node scripts/post-deploy-bil-vault.mjs
```

Idempotent — re-running skips already-granted roles + already-seeded
positions. Total gas ~300K for grants + ~3M for seed (Decentral
`createPosition` is the heavy step). Source ~100 HOLLAR on the deployer
before running with `SEED_AMOUNT`.

After verifying state, rotate admin/upgrader roles to governance:

```sh
RPC=… PRIVATE_KEY=0x<deployer> VAULT_ADDRESS=<MAINNET_VAULT> \
  NEW_ADMIN=<governance> \
  node scripts/post-deploy-bil-vault.mjs
```

This grants `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` / `UPGRADER_ROLE` to
`NEW_ADMIN` first, **then** renounces the deployer's copies. The order
matters — never have zero admins. Once renounced, the deployer can't
recover admin via the same key.

Post-deploy invariants (script verifies last three automatically; see
`bil-vault/DEPLOYMENT.md` for the full list):

- `vault.totalAssets() > 0` + `vault.totalSupply() > 0` (after seed)
- `vault.exchangeRate() ≈ 1e18` (±10 wei)
- `vault.getOraclePrice() > 0`
- `vault.hasRole(GUARDIAN_ROLE, <tech-committee>) == true`
- `vault.hasRole(CLAIM_OPERATOR_ROLE, <keeper>) == true`
- (after rotation) `vault.hasRole(ADMIN_ROLE, <deployer>) == false`

---

## 1. Deploy the WDCL oracle adapter

The market prices BIL collateral off the vault's `exchangeRate()`. Deploy the
Chainlink-compatible adapter against the **mainnet** vault:

```sh
HARDHAT_NETWORK=hydration npx hardhat deploy-BILOracleAdapter --vault <MAINNET_VAULT>
```

Paste the resulting address into `markets/bil/index.ts` →
`ChainlinkAggregator[eHydrationNetwork.hydration].BIL`. (The raw `BILOracle`
from the vault deploy reads the same rate but only implements the slim
AggregatorV3 surface; the adapter adds the `IEACAggregatorProxy` interface Aave's
oracle infra + MMOracle peg resolver need — deploy the adapter.)

Verify: `cast call <adapter> 'latestAnswer()(int256)'` ≈ `1.00e8` at launch.

---

## 2. Deploy the BIL Aave market core

```sh
MARKET_NAME=BIL HARDHAT_NETWORK=hydration npx hardhat deploy --network hydration
```

This deploys: `PoolAddressesProvider-BIL`, `Pool`, `PoolConfigurator`,
`ACLManager-BIL`, `AaveOracle-BIL`, the aToken/debt-token implementations,
rate strategies, `PoolDataProvider-BIL`. Three things happen automatically
thanks to config baked in during the lark-2 rehearsal:

- **Treasury is reused** — `ReserveFactorTreasuryAddress[hydration]` points at the
  main MM treasury, so `deploy/01_periphery_pre/01_treasury.ts` adopts it instead
  of deploying a new one.
- **Registry is reused** — `EXISTING_PROVIDER_REGISTRY[hydration]` points at the
  main MM registry, so `deploy/00_core/00_markets_registry.ts` adopts it.
  The BIL provider is **not** registered into it here (registry is
  governance-owned) — that's deferred to the proposal (Phase 5).
- **Reserve init is skipped** — BIL's underlying asset (substrate asset id 550)
  isn't registered yet, so `09_init_reserves.ts` skips it ("defer to governance
  proposal") and `01-after-deploy.ts` skips the reserve-config tasks
  (zero-reserve guard). The market deploys as an empty, admin-owned shell.

The native-token gateway is skipped for the BIL market (Hydration represents
every token as an ERC20-via-precompile — no native wrap).

Record `Pool-Proxy-BIL` and `PoolAddressesProvider-BIL` from
`deployments/hydration/`.

---

## 3. Deploy the 4 GHO/HOLLAR facilitator implementations (hollar repo)

The HOLLAR borrow side uses GHO-style aToken/debt implementations parameterized
for the BIL pool. These live in **`hollar` (branch `feat/bil`)**, not here.

1. Seed `hollar/deployments/hydration/` with the BIL pool + provider artifacts
   (so `getPool()` / `getPoolAddressesProvider()` resolve), or rely on the
   existing mainnet artifacts.
2. Deploy:
   ```sh
   # in ../hollar (feat/bil)
   MARKET_NAME=BIL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
     npx hardhat deploy --network hydration --tags bil_hollar_deploy
   ```
   Produces `GhoAToken-BIL`, `GhoStableDebtToken-BIL`,
   `GhoVariableDebtToken-BIL`, `GhoInterestRateStrategy-BIL`.
3. Copy those 4 artifacts into `aave-v3-deploy/deployments/hydration/` (the
   proposal task reads them via `hre.deployments.get`).

---

## 4. Deploy the BILDepositZap

```sh
HARDHAT_NETWORK=hydration npx hardhat deploy-BILDepositZap \
  --hollar 0x531a654d1696ED52e7275A8cede955E82620f99a \
  --vault <MAINNET_VAULT> \
  --pool <Pool-Proxy-BIL> \
  --precompile 0x0000000000000000000000000000000100000226   # asset 550 (BIL)
```

(The zap atomically does HOLLAR.transferFrom → `vault.deposit(assets, receiver=zap)`
→ `pool.supply` — needed because a substrate batch can't chain the exact mint
amount into `pool.supply`, and `supply` won't accept a sentinel "all".)

---

## 5. Transfer protocol ownership (last step before governance)

Hand the new market's roles to the on-chain admin **before** the governance
proposal — so the proposal can already dispatch as the configured admin.

```sh
MARKET_NAME=BIL HARDHAT_NETWORK=hydration npx hardhat transfer-protocol-ownership \
  --network hydration
```

Target role-holders on the BIL ACLManager after this step:

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0xaa7e0000000000000000000000000000000aa7e0` (aave-manager precompile) |
| `POOL_ADMIN` | `0xaa7e0000000000000000000000000000000aa7e0` (precompile) |
| `EMERGENCY_ADMIN` | `0xaa7e0000000000000000000000000000000aa7e0` (precompile — same as PoolAdmin; what the task grants by default) |
| `PoolAddressesProvider-BIL` owner | `0xaa7e0000000000000000000000000000000aa7e0` (precompile) |

Verify final state before proceeding:

```sh
ACL=<ACLManager-BIL>
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

**BIL launch parameters** (source of truth: `markets/bil/reservesConfigs.ts`
in this repo; `helpers/config.ts` in the `hollar` repo):

| Parameter | Value | Source |
|---|---|---|
| BIL `baseLTVAsCollateral` | 8000 (80%) | `reservesConfigs.ts` |
| BIL `liquidationThreshold` | 8500 (85%) | `reservesConfigs.ts` |
| BIL `liquidationBonus` | 10700 (7%) | `reservesConfigs.ts` |
| BIL `liquidationProtocolFee` | 1000 (10%) | `reservesConfigs.ts` |
| BIL `reserveFactor` | 2000 (20%) | `reservesConfigs.ts` |
| BIL `supplyCap` | 3_000_000 | `reservesConfigs.ts` |
| BIL `borrowingEnabled` | false | `reservesConfigs.ts` |
| HOLLAR borrow rate | **10% APY** (= 9.531% APR in ray) | `hollar/helpers/config.ts` (`apyToAprPercent(10)`) |
| HOLLAR facilitator cap | 1_000_000 HOLLAR | `hollar/helpers/config.ts` (`bilEntityConfig.mintLimit`) |
| BIL provider id (registry) | 22222255 | `markets/bil/index.ts` |

These get baked into the proposal hex by `tasks/proposals/bil.ts`. Verify them
in the decoded proposal print-out before submitting.

Generate the proposal preimage:

```sh
MARKET_NAME=BIL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
  npx hardhat bil --network hydration
```

The proposal (`tasks/proposals/bil.ts`) bundles, as a `utility.batchAll` run as
Root, in the order below. Critical: **the BIL substrate register runs first** —
the substrate→EVM ERC20 precompile needs `decimals()` to resolve, which requires
asset 550 to already be registered before EVM `initReserves(BIL)` is dispatched.
The task hoists this automatically (`txs.unshift`).

1. **Substrate: `assetRegistry.register(550, BIL → vault)`** — must precede #3
2. `AaveOracle-BIL.setAssetSources(BIL → adapter)`
3. `PoolConfigurator.initReserves([BIL])` — collateral reserve, treasury reused
4. `ReservesSetupHelper.configureReserves(BIL: 80% LTV, 85% liq, 3M supply cap, borrow disabled)`
5. `PoolConfigurator.setLiquidationProtocolFee(BIL, 10%)`
6. **`PoolAddressesProviderRegistry.registerAddressesProvider(BIL provider, 22222255)`** — into the shared main registry
7. `PoolConfigurator.initReserves([HOLLAR])` — GhoAToken facilitator impls, treasury reused
8. `setReserveBorrowing(HOLLAR, true)`
9. `AaveOracle-BIL.setAssetSources(HOLLAR → GhoOracle)`
10. `HOLLAR.addFacilitator(GhoAToken proxy, "BIL", 1M cap)`
11. GHO cross-refs on `GhoAToken-BIL`: `setVariableDebtToken`, `updateGhoTreasury`
12. GHO cross-refs on `GhoVariableDebtToken-BIL`: `setAToken`, `updateDiscountRateStrategy`, `updateDiscountToken(HOLLAR)`
13. Substrate: `assetRegistry.register(55, BIL → BIL aToken proxy)`
14. Substrate: `multiTransactionPayment.addCurrency` (BIL, BIL as fee currencies)
15. Substrate: `evmAccounts.approveContract(Pool-Proxy-BIL)` (managed-balance — saves users from per-ERC20 approve before `pool.supply` / `repay`)
16. **Stablepool bootstrap** (via `buildStablepoolTxs` from `bil-stablepool-lark.ts`):
    - Substrate: `assetRegistry.register(10055, 2-Pool-BIL, StableSwap)`
    - Substrate: `multiTransactionPayment.addCurrency(10055)` (reuses HOLLAR's price)
    - Substrate: `stableswap.createPoolWithPegs(10055, [55, 222], A=100, fee=0.10%, peg=[MMOracle(BILOracleAdapter), Value(1,1)], maxPegUpdate=2%)`
    - Substrate: `scheduler.scheduleAfter(1, batchAll([…]))` — Treasury bootstrap, runs 1 block later: borrow 600K HOLLAR from main MM, approve zap, `zap.depositAndSupply(300K HOLLAR)`, `stableswap.addAssetsLiquidity(10055, [BIL: ~296.7K, HOLLAR: 300K])`. All four inner calls are `dispatcher.dispatchAs(treasury, …)`.

All EVM calls are wrapped via `aaveManagerCall` (`dispatcher.dispatchAsAaveManager`,
source = aave-manager precompile). The task prints both the **whitelisted-call
hash** and the **bare batchAll hex** ("Encoded proposal"). Watch the log line
`reordered: BIL substrate register moved <idx> → 0` — that confirms the hoist
fired and the ordering bug is avoided.

Step 16 (stablepool) is **idempotent at the proposal level** — if asset 10055 is
already registered when the task runs, the stablepool helper throws
`already registered` and `bil.ts` catches that and skips Phase E.5 without
aborting the rest. This lets the proposal be re-built safely after a partial
landing. For networks where the main launch ran but the stablepool didn't (e.g.
lark-2 prior to ref #399), use the standalone `bil-stablepool-patch` task to
submit JUST the stablepool delta.

**Pre-flight on the stablepool step**: Treasury needs ≥600K HOLLAR of borrow
capacity on the **main MM** (i.e. enough existing collateral to back the
bootstrap loan). On lark-2 Treasury has ~$2.3M available borrows; the task
warns and continues if mainnet's headroom drops below 600K — verify before
submitting.

### Submitting on mainnet
Per current intent, **not** using the TC-whitelist track. Submit the bare
batchAll on the appropriate OpenGov track and let it run the normal referendum
→ vote → enactment cycle. Idempotency guards in the task mean a re-run after a
partial landing is safe (skips already-registered assets/facilitator/provider).

### Verify after enactment

Wait for the enactment block, then check events + state:

```sh
MARKET_NAME=BIL HARDHAT_NETWORK=hydration RPC=<mainnet-rpc> \
  PROPOSAL_WS=<mainnet-ws> \
  npx hardhat run scripts/verify-bil-state.ts --network hydration
```

Every assertion must pass (same expected values as the dry-run section). Then
scan the enactment block's events: every `dispatchAsAaveManager` → `evm.call`
must be `evm.Executed`, **not** `evm.ExecutedFailed` — substrate `evm.call`
returns `Ok` even on internal EVM revert, so the only reliable signal is the
events list.

### Dry-run first (gc chopsticks ≥ 2.2.0)
The lark-2 rehearsal proved `scripts/submit-bil-proposal.ts` works against a
gc chopsticks fork. Same flow for the mainnet dry-run, using
**`@galacticcouncil/chopsticks@2.2.0`** (or later) — published to npm, no
workspace-symlink hacks needed:

```sh
# terminal 1 — chopsticks against mainnet
# Either from the gc fork repo:
cd ~/git/chopsticks
node packages/chopsticks/chopsticks.cjs --config configs/hydradx.yml --port 8000
# (configs/hydradx.yml has mainnet endpoints baked in + the Alice storage hacks)
#
# Or via npx, no local checkout needed:
# npx @galacticcouncil/chopsticks@^2.2.0 --endpoint wss://rpc.hydradx.cloud --port 8000

# terminal 2 — submit + enact in one pass (regenerates the proposal, flips
# chopsticks to Instant block mode, bumps Alice to 5B HDX, votes on Root, scans
# events). PROPOSAL_WS points the script at chopsticks; HARDHAT_NETWORK + RPC
# point ethers/hardhat at the same fork so address resolution matches.
MARKET_NAME=BIL HARDHAT_NETWORK=hydration RPC=http://localhost:8000 \
  PROPOSAL_WS=ws://localhost:8000 \
  npx hardhat run scripts/submit-bil-proposal.ts --network hydration
```

The script (idempotent — safe to re-run after a partial landing):
- Calls `dev_setBlockBuildMode("Instant")` so each tx auto-seals a block (the
  `--build-block-mode Instant` startup flag still fails on Hydration's
  parachain inherents; flipping at runtime works).
- Bumps Alice's free balance to ≥5B HDX via `dev_setStorage` (gc's hydradx.yml
  `import-storage` truncates her to ~1000 HDX otherwise).
- Submits the batchAll on the Root track, places decision deposit, votes aye with
  full conviction, fast-forwards via `dev_newBlock` until approval + enactment.

Inspect the post-enactment events: every `dispatchAsAaveManager` → `evm.call`
must emit `evm.Executed`, not `evm.ExecutedFailed` (substrate `evm.call` returns
`Ok` even on internal EVM revert — **check the events, not the extrinsic result**).
Then run the state verification:

```sh
MARKET_NAME=BIL HARDHAT_NETWORK=hydration RPC=http://localhost:8000 \
  PROPOSAL_WS=ws://localhost:8000 \
  npx hardhat run scripts/verify-bil-state.ts --network hydration
```

Expected output (all ✓):
- 2 reserves: BIL + HOLLAR
- BIL: LTV 8000, liqThreshold 8500, supplyCap 3M, borrowing off, collateral on,
  liqProtocolFee 1000, price ≈ vault exchange rate × 1e8
- HOLLAR: borrowing on, collateral off, price 1e8
- HOLLAR facilitator: label `BIL`, bucketCapacity 1e24 (1M × 1e18), level 0
- ACL: precompile is PoolAdmin + EmergencyAdmin, deployer is not
- ProviderRegistry: BIL id 22222255, total providers 2
- Substrate asset 550 (BIL) → vault, Erc20, fee currency
- Substrate asset 55 (BIL) → aToken proxy, Erc20, fee currency
- `evmAccounts.approvedContract(Pool-Proxy-BIL)` = true

#### Deploy-time smoke tests (optional, recommended)

chopsticks 2.2.0 implements the full EVM client surface (`eth_sendRawTransaction`,
`eth_getTransactionReceipt`, `eth_getLogs`, etc.) — so you can also dry-run the
Phase-1 oracle adapter deploy + Phase-4 zap deploy against the same fork before
the proposal:

```sh
# Flip chopsticks to Instant mode + fund a test EVM address with WETH (asset 20)
curl -sX POST http://localhost:8000 -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"dev_setBlockBuildMode","params":["Instant"]}'
node scripts/fund-test-deployer.mjs

# Deploy BILOracleAdapter against the live forked vault + sanity-check
node scripts/smoke-test-bil-on-chopsticks.mjs
# → status: success, latestAnswer ≈ $1.00 from the live vault state
```

See [chopsticks-testing-hydration](https://garden.intergalactic.limited/wiki/chopsticks-testing-hydration/)
for the canonical chopsticks runbook (including the WETH-not-HDX funding model
for `pallet-evm`'s gas currency, the `2.lark` vs `0.lark` shard gotcha, and the
Instant-mode-is-fire-and-forget race condition).

> Stale tool note: `moonbeam-tools fast-execute-chopstick-proposal.ts`
> (force-enact without a vote) is still broken as of 2026-06 —
> `@moonbeam-network/api-augment` doesn't resolve against the installed
> `@polkadot/types`. The submit-and-vote flow above replaces it for BIL.

---

## 7. Flip the UI on

In `hydration-ui` (`feat/bil`), set in
`apps/main/src/modules/strategies/bil/constants.ts`:

```ts
export const BIL_HAS_AAVE_LAYER = true
export const BIL_POOL_ADDRESS         = "<Pool-Proxy-BIL on mainnet>"
export const BIL_ATOKEN_ADDRESS       = "<BIL aToken proxy on mainnet>"
export const BIL_DEPOSIT_ZAP_ADDRESS  = "<BILDepositZap on mainnet>"
```

Lark-2 reference values (already committed on `feat/bil`):

```ts
BIL_POOL_ADDRESS         = "0xEAb87D2aAc4C70AF63D2d9E85876665060e117E2"
BIL_ATOKEN_ADDRESS       = "0x8912ff2164655A3406902ee9e802EBb16ec881D9"
BIL_DEPOSIT_ZAP_ADDRESS  = "0x146F6C43a0070F42cB532C74c412A34bb55A5729"
```

Borrow / supply-as-collateral / instant-redeem flows are already coded behind
that flag — they light up once it's true.

---

## Asset-id scheme (substrate registry)

| id | name | location target | role |
|---|---|---|---|
| 550 | BIL | vault proxy | pool's underlying reserve asset |
| 55 | BIL | BIL aToken proxy | user-facing collateral receipt |

Both registered as `Erc20` so the substrate→EVM precompile bridges to the EVM
contract (without it, `pool.supply` / transfers via the precompile see zero
substrate balance and revert).

---

## Lark-2 rehearsal — concrete addresses (reference)

**Status: complete.** BIL market live on lark-2; governance proposal enacted
via Root referendum #383 at block 222762, parameter patch (LTV/LT 70/80 →
80/85) via #384, rate-strategy revert (10% APR → 10% APY) via #385,
**stablepool bootstrap** (ref #399 at block 298146) — 2-Pool-BIL stableswap
created with 296.7K BIL + 300K HOLLAR initial liquidity from Treasury, fast
withdrawals now possible. UI flipped on `feat/bil` (commit `ab3f64bda`).
End-state verified by `scripts/verify-bil-state.ts`; tight-leverage loop
converged to 4.99x at HF 1.0628 with theoretical net APR ≈ 51.83% on equity
(vault 18% APY, borrow 9.53% APR).

| Contract | lark-2 address |
|---|---|
| Vault | `0xbDAFEB92440d8696d6C143bc7e6B086d461e3502` |
| BILOracleAdapter | `0xAc4C01AbA189d90eCD707938D545f47535843642` |
| PoolAddressesProvider-BIL | `0x4E75BA5d5EEa7f63F2B43F41913252391Eb3e147` |
| Pool-Proxy-BIL | `0xEAb87D2aAc4C70AF63D2d9E85876665060e117E2` |
| AaveOracle-BIL | `0x86c03F1920dE43D3D359487160e1CC1eC44FB319` |
| BILDepositZap | `0x146F6C43a0070F42cB532C74c412A34bb55A5729` |
| GhoAToken-BIL | `0x81d6f4Fe5A2AF0113de51F1c3e8019A731DcF817` |
| GhoStableDebtToken-BIL | `0x48A87CB6CCE74E356F80846cd90e7de52c7D2e96` |
| GhoVariableDebtToken-BIL | `0x6E712A053a83De7C3e6261b2d4D3c0886D3C03BD` |
| GhoInterestRateStrategy-BIL | `0x692F293B6a0486af92e8572C7Ef246cBCCD4Fa0E` |

Mainnet addresses will differ; treasury + registry + HOLLAR + GhoOracle +
ZeroDiscountRateStrategy + aave-manager precompile are identical (mainnet is the
fork source).
