# BIL Mainnet Deployment Handover

This document is the authoritative runbook for launching the BIL Aave V3
instance on Hydration mainnet. It supersedes the earlier `BIL-DEPLOYMENT.md`
phase plan — that one had phases 3 and 4 in the wrong order and missed the
admin-transfer step, both of which bit us hard on 0.lark.

**Status at time of writing (2026-04-23):** BIL launched successfully on
0.lark after multiple recovery runs. Ref 324 on 0.lark was the clean
execution. All addresses + artifacts captured in `deployments/lark/`.

## Components and naming

The substrate-side asset names are **not** the same as the EVM contract
names — what users see in their wallet is dictated by the assetRegistry, not
the underlying contract's `symbol()`. The naming is intentional:

| Asset id | Registry name | What it is | Location target | Why users see it |
|---|---|---|---|---|
| 550 | **BIL** | Vault token (`BILVault.sol`). The user-deposits-HOLLAR-gets-this thing. | vault proxy | Brief — the UI auto-supplies BIL into the Aave pool, so users hold it for milliseconds at most. |
| 55 | **BIL** | aToken receipt for the BIL reserve in the Aave pool. | BIL aToken proxy | This is what users actually hold. Their balance grows as the pool earns yield. |

This mirrors the GDOT pattern — the user-facing token has the marketed name
(BIL), the underlying that the auto-deposit unwraps into has its own name
(BIL).

Components:

- **BIL Vault** — `aave-v3-deploy/bil-vault/` (Foundry). Users deposit
  HOLLAR, get BIL vault shares (asset 550), vault deploys HOLLAR into
  Decentral. The UI then auto-supplies BIL into the BIL Aave pool to mint
  BIL aToken (asset 55) to the user.
- **BILOracleAdapter** — `aave-v3-deploy/contracts/BILOracleAdapter.sol`.
  Chainlink wrapper reading `vault.exchangeRate()`, scaled 18→8 decimals.
  Implements **both** the legacy `IEACAggregatorProxy` (consumed by Aave's
  AaveOracle as the price source for the BIL reserve) **and** the modern
  Chainlink V3 `AggregatorV3Interface` (`latestRoundData`, `getRoundData`,
  `description`, `version`) — required by Hydration's stableswap pallet
  `MMOracle` peg-source resolver. Without the V3 surface,
  `stableswap.create_pool_with_pegs` errors with `MissingTargetPegOracle`
  (lesson 11). Mainnet deploys a single oracle for both consumers; lark was
  re-deployed and the existing BIL pool's AaveOracle is re-pointed via the
  stablepool launch proposal (so there's only one source of truth).
- **BILDepositZap** — `aave-v3-deploy/contracts/BILDepositZap.sol`.
  Atomic helper that bundles `HOLLAR.transferFrom + vault.deposit +
  pool.supply` into one EVM call, using `vault.deposit`'s exact return value
  for the supply step (no off-chain `previewDeposit` prediction). This is
  what lets the UI present a single-signature "deposit HOLLAR → end up
  holding BIL aToken" flow without leaving dust in the user's wallet on
  every batch. See lesson 10 below for why a separate substrate
  `Utility.batch_all` of `vault.deposit + pool.supply` doesn't work.
- **BIL Aave pool** — separate Aave V3 instance. ProviderId `22222255`. BIL
  supply-only collateral, HOLLAR borrow-only (via GhoAToken facilitator).
- **HOLLAR GHO impls** — per-pool BIL-specific versions of `GhoAToken-BIL`,
  `GhoStableDebtToken-BIL`, `GhoVariableDebtToken-BIL`,
  `GhoInterestRateStrategy-BIL` (fixed 10% APR). Built in the `hollar` repo.
  Naming follows the pool name (`BIL`), not the asset name.
- **Governance proposal** — single `batchAll` containing init-reserve + config
  calls (EVM, via `dispatcher.dispatchAsAaveManager`) plus substrate
  `assetRegistry.register`, `multiTransactionPayment.addCurrency`, and
  `EVMAccounts.approve_contract(Pool-Proxy-BIL)` calls.

## Correct phase ordering

The phase order below describes the **lark staged launch**. For the mainnet
single-batch launch, see "Mainnet single-batch launch composition" below —
it adds the BIL/HOLLAR stableswap pool + Treasury liquidity bootstrap,
moves BILDepositZap deploy earlier (before proposal generation), and
swaps in a different proposal task.

1. **Deploy BIL Vault** (Foundry, direct EVM deploy)
2. **Deploy BILOracleAdapter** (hardhat task `deploy-BILOracleAdapter`, constructor takes vault proxy)
3. **Wire oracle address into market config** — `markets/bil/index.ts`
   `ChainlinkAggregator[<network>].BIL`
4. **Deploy Aave pool infrastructure** (`npm run deploy -- --tags market`).
   Reserve init is deferred (asset precompile not responsive yet) — the
   skip-guard in `09_init_reserves.ts` handles this.
5. **Deploy HOLLAR GHO impls** — in the `hollar` repo, tag `bil_hollar_deploy`.
6. **Copy GHO + HOLLAR artifacts** from `hollar/deployments/<network>/` → 
   `aave-v3-deploy/deployments/<network>/`. Also needed:
   - `HOLLAR.json` (the HOLLAR token artifact — pre-existing on mainnet)
   - `ZeroDiscountRateStrategy.json` (pre-existing on mainnet)
7. **CRITICAL: Transfer admin to governance precompile**.
   Run `scripts/transfer-bil-admin-to-governance.ts`. This grants
   `DEFAULT_ADMIN_ROLE` / `POOL_ADMIN` / `RISK_ADMIN` / `EMERGENCY_ADMIN` on
   `ACLManager-BIL` to `0xaa7e0000000000000000000000000000000aa7e0` and
   transfers `PoolAddressesProvider-BIL` ACL-admin + ownership to it.
   **Without this step the governance proposal dispatches EVM calls as
   `0xaa7e...` but `0xaa7e...` isn't a pool admin, so every call silently
   reverts inside the dispatcher.**
8. **Grant RISK_ADMIN to ReservesSetupHelper** — run
   `scripts/grant-bil-risk-admin.ts`. Required for the `configureReserves`
   call inside the proposal's Phase A.
9. **Generate governance proposal** (`npx hardhat bil`). Inspect the
   decoded call tree.
10. **Dry-run on chopsticks** (see "Dry-run" section below).
11. **Submit on mainnet governance** (WhitelistedCaller track, NOT Root — see
    "Governance submission" below).
12. **Verify** with full event log scan + pool state queries.
13. **Deploy BILDepositZap** — once governance has registered BIL as Erc20
    and whitelisted Pool-Proxy-BIL in `EVMAccounts.ApprovedContract` (both
    happen in Phase D of the proposal), deploy the zap helper:
    ```bash
    HARDHAT_NETWORK=<network> MARKET_NAME=BIL npx hardhat deploy-BILDepositZap \
      --hollar     <HOLLAR address> \
      --vault      <vault proxy address> \
      --pool       <Pool-Proxy-BIL address> \
      --precompile 0x0000000000000000000000000000000100000037
    ```
    The constructor max-approves `HOLLAR → VAULT` so subsequent
    `vault.deposit` calls don't need per-tx approvals from the zap. Verify
    `zap.HOLLAR.allowance(zap, vault) == 2^256 − 1` after deploy.
14. **UI update** — bump vault/pool/oracle/**zap** addresses in
    `hydration-ui/apps/main/src/modules/bil-vault/constants.ts`
    (`BIL_DEPOSIT_ZAP_ADDRESS` is what the UI's `useDeposit` calls
    instead of vault.deposit + pool.supply directly). Also any
    money-market pool registry.

## What the proposal `batchAll` does (current source of truth)

The BIL governance proposal task at `tasks/proposals/bil.ts` builds these
calls. Every substrate call is idempotent — re-submission after a partial
failure is safe.

**Phase A — BIL collateral reserve (EVM via dispatchAsAaveManager):**
- `init-reserve BIL` → `pool.initReserves(...)` for the BIL underlying
  (asset 550 / vault token) with the standard AToken / StableDebtToken /
  VariableDebtToken impls and `rateStrategyStables`. The aToken proxy this
  creates is the address the substrate registry binds to "BIL" (asset 55)
  in Phase D.
- `configureReserves` → applies LTV 70 / LiqThresh 80 / liquidation bonus 7% /
  reserve factor 20% / supply cap 3M / borrow disabled / debt ceiling 0.
- `setupLiquidationProtocolFee` → 10%.

**Phase B — HOLLAR borrow reserve (EVM via dispatchAsAaveManager):**
- `pool.initReserves` for HOLLAR using the BIL-specific `GhoAToken-BIL` /
  `GhoStableDebtToken-BIL` / `GhoVariableDebtToken-BIL` impls and
  `GhoInterestRateStrategy-BIL` (fixed 10% APR).
- `setReserveBorrowing(HOLLAR, true)`.
- `AaveOracle-BIL.setAssetSources([HOLLAR], [GhoOracle])`.

**Phase C — HOLLAR facilitator + GHO cross-references (EVM via dispatchAsAaveManager):**
- `HOLLAR.addFacilitator(predictedGhoAToken, "BIL", 1M HOLLAR)` — *skipped if
  bucket already set up*.
- `GhoAToken.setVariableDebtToken(predictedGhoVariableDebt)`.
- `GhoAToken.updateGhoTreasury(treasury)`.
- `GhoVariableDebt.setAToken(predictedGhoAToken)`.
- `GhoVariableDebt.updateDiscountRateStrategy(ZeroDiscountRateStrategy)`.
- `GhoVariableDebt.updateDiscountToken(HOLLAR)`.

The predicted addresses use a nonce-offset that auto-detects whether BIL is
already initialized (offset 0) or being initialized in this batch (offset 3).

**Phase D — Substrate (root):**
- `assetRegistry.register(550, **BIL**, Erc20, location → vault proxy)` —
  the underlying vault token. Skipped if already registered; if location
  drifted, emits `assetRegistry.update`.
- `assetRegistry.register(55, **BIL**, Erc20, location → BIL aToken proxy)`
  — the user-facing aToken receipt. Same idempotency.
- `multiTransactionPayment.addCurrency(550, HOLLAR_price)` — BIL accepted
  for fees. Skipped if already accepted.
- `multiTransactionPayment.addCurrency(55, HOLLAR_price)` — BIL accepted
  for fees. Skipped if already accepted.
- `EVMAccounts.approve_contract(Pool-Proxy-BIL)` — adds the pool to
  Hydration's managed-balance approved-contract list so users don't need a
  separate `IERC20.approve(pool, ...)` before `pool.supply`. Idempotent.

The vault proxy address used for BIL's `location` is read at proposal-build
time from the on-chain `BILOracleAdapter.vault()` getter, so it's correct on
any network without hardcoding. The BIL aToken proxy address used for BIL's
`location` is computed from PoolConfigurator's nonce (offset 0 if BIL reserve
is already initialized, else current nonce — see Phase C nonce-prediction).

## Mainnet single-batch launch composition

Lark launched in stages — BIL pool first, then BILDepositZap separately,
with the stableswap exit deferred entirely (still unbuilt as of this
writing). **Mainnet ships everything in a single referendum**: vault, pool,
governance config, the deposit zap, the BIL/HOLLAR stableswap pool, AND
the Treasury bootstrap of initial liquidity. This section specifies the
pieces that lark didn't run, so the next person preparing mainnet has
every parameter and rationale captured.

> The lark task `tasks/proposals/bil.ts` is the staged version. Mainnet
> uses a NEW task `tasks/proposals/bil-mainnet-launch.ts` (to be written,
> mirroring `heurc-launch.ts` structure) which composes the full
> single-batch shape: the existing BIL governance contents PLUS everything
> below.

### New components

#### `2-Pool-BIL` — stableswap LP token (asset 10055)

Convention follows HEURC's 10044 (`10000 + reserve-symbol-numeric-id`).
Registered alongside the existing BIL/BIL registrations in Phase D, as a
third `assetRegistry.register` call with:

| Field | Value | Notes |
|---|---|---|
| `id` | 10055 | Mirrors HEURC's 10044 / sUSDe's 10043 / etc. |
| `name` | "2-Pool-BIL" | |
| `assetType` | `"StableSwap"` | |
| `symbol` | "2-Pool-BIL" | |
| `decimals` | 18 | |
| `existentialDeposit` | `17241379310344828` | Matches HEURC convention for 18-decimal stableswap LP tokens |
| `location` | `null` | StableSwap LP tokens have no XCM location |
| `xcmRateLimit` | `parseEther("1500000")` | Matches HEURC |
| `isSufficient` | `true` | |

Also: `multiTransactionPayment.addCurrency(10055, <hollar-pegged price>)`
to allow the LP token as a fee-payment asset.

#### Stableswap pool: BIL ↔ HOLLAR

Created via `stableswap.createPoolWithPegs(...)`:

| Field | Value | Reasoning |
|---|---|---|
| `shareAsset` | 10055 | The 2-Pool-BIL LP token registered above |
| `assets` | `[55, 222]` | **Sorted ascending** — BIL(55) before HOLLAR(222). Inversion silently produces wrong pool composition. |
| `amplification` | 100 | Matches gigaeth/gigasol — high stability for yield-bearing collateral with slow-drifting peg |
| `fee` | 1000 | 0.1%. Covers the secondary-market exit cost; 2× HEURC's 0.05% to mildly discourage instant exit unless really needed (queue is the cheaper path) |
| `pegSource[0]` | `{ MMOracle: <BILOracleAdapter address> }` | BIL's peg source. **Reuses the same oracle deployed for the Aave reserve** — wraps `vault.exchangeRate()` and scaled 18→8 decimals. **Must implement Chainlink V3 `AggregatorV3Interface`** (`latestRoundData`, etc.) — the stableswap pallet's MMOracle resolver calls `latestRoundData()`, not the legacy `latestAnswer()`. Lesson 11 captures the lark debugging history; the current `BILOracleAdapter.sol` in this repo has both interfaces and works for both consumers. |
| `pegSource[1]` | `{ value: [1, 1] }` | HOLLAR fixed 1:1 base reference |
| `maxPegUpdate` | 200 | Gigasol's "≥10× expected APY" rule applied to BIL's ~18% APY = floor of 180, rounded to 200. Sits in the same magnitude as gigasol(160 for 7% APY) and prime(120) — both yield-bearing rebase tokens. ~4× margin over BIL's natural daily drift (~0.05%/day): tight enough to bound oracle manipulation, loose enough to never throttle yield accrual. **Caveat: if you can find someone on the chain team who knows the pallet definition of this unit, worth confirming before locking in.** |

#### Router routes — fee-payment conversion

Hydration's `multiTransactionPayment` lets users pay extrinsic fees in
any accepted currency. To convert a fee paid in (say) WETH into the
BIL ecosystem, the router needs an explicit hop chain registered via
`router.forceInsertRoute`. Without these routes, users CAN still hold
BIL/aBIL and use the pool, but **they can't pay fees in H2O / WETH
while interacting with BIL surfaces** — the router has no path from
the source fee asset to the new pool's tokens, so the fee-conversion
step fails.

(The UI's liquidity tab and wallet visibility of the new pool/LP token
is independent of routes — those work as soon as the asset is
registered. Lark needed a hard browser refresh to clear the cached
asset list; routes weren't the issue there.)

The pattern (from `hollar-pools-launch.ts` + `gigaeth-launch.ts`): one
route per fee-currency source, ending at the **user-held asset** (BIL =
the aToken — asset 55 on mainnet, asset 550 on lark), with the new
stableswap as a hop.

For mainnet (BIL = asset 55 after the new naming flip):

| `assetIn` → `assetOut` | Route hops |
|---|---|
| `H2O (1) → BIL (55)` | `[Omnipool: 1→222, Stableswap 10055: 222→55]` |
| `WETH (20) → BIL (55)` | `[Stableswap: 104, 20→1007], [Stableswap: 4200, 1007→4200], [Aave: 4200→420], [Omnipool: 420→222], [Stableswap: 10055, 222→55]` |

(For the lark variant the destination is asset **550** instead of 55,
and the Stableswap 10055 last hop reads `222→550` — the rest of the
chain is identical.)

Routes between assets that are already in the same pool (`222 ↔ 55` for
mainnet, `222 ↔ 550` for lark) are NOT needed — the router infers them
from pool membership.

If you want fee-payment conversion to also reach **BIL** (the vault
underlying — asset 550 on mainnet, asset 55 on lark), add 2 more
forceInsertRoute calls appending `[Aave: aToken_id → vault_id]` to
each path. Lark stopped at the BIL routes; product call.

#### Treasury bootstrap (post-pool-creation, scheduled batch)

Initial liquidity comes from Treasury, in the same referendum. Steps,
wrapped in `dispatchAs(treasury, ...)` and scheduled via
`scheduler.scheduleAfter(N, ...)` so the pool exists *before* liquidity flows:

1. **Borrow 600K HOLLAR from the main money market.**
   ```
   pool.borrow(HOLLAR_addr, 600000e18, 2, 0, treasury)
   ```
   Variable rate (interestRateMode=2 — required for HOLLAR via the GhoAToken
   facilitator), no referral code, on-behalf of treasury. Borrows against
   Treasury's existing collateral on the main MM.

2. **Approve BILDepositZap for 300K HOLLAR.**
   ```
   HOLLAR.approve(BILDepositZap, 300000e18)
   ```
   Single-shot allowance.

3. **Deposit 300K HOLLAR via the zap → mint ≈300K BIL aToken atomic.**
   ```
   zap.depositAndSupply(300000e18)
   ```
   Produces ≈300K BIL (asset 55) in Treasury's wallet. Atomic at the EVM
   level (lesson 9). Exact mint amount = `300000e18 / vault.exchangeRate()`
   at execution time — slightly less than 300K if the rate has accrued
   since proposal-build, but that's fine for `addAssetsLiquidity` (which
   takes exact amounts; treasury just specifies what it actually has).

4. **Add liquidity to the new pool.**
   ```
   stableswap.addAssetsLiquidity({
     poolId: 10055,
     assets: [
       { assetId: 55,  amount: <actual BIL minted> },  // BIL first
       { assetId: 222, amount: 300000e18 },             // HOLLAR second
     ],
     minShares: 0,
   })
   ```
   Treasury receives LP tokens (asset 10055).

After step 4, Treasury holds the LP shares. The 600K HOLLAR borrow leaves a
600K variable-rate HOLLAR debt against Treasury's main-MM collateral —
maintained as ongoing protocol-owned liquidity exposure.

> **Note on amount precision in step 4.** The proposal task can either:
> (a) hardcode `300000e18` and accept that a tiny dust of BIL stays in
> treasury's wallet (acceptable but not ideal), or (b) wrap step 3+4 in a
> small "addAllAvailableBil" helper precompile that reads the actual
> balance and forwards it. Pick (a) for simplicity — the dust is the
> per-block yield delta between proposal-build and execution, on the order
> of cents.

### Updated phase ordering for mainnet

The 14-step lark playbook still applies, with these mainnet-specific
changes:

| Lark phase | Mainnet change |
|---|---|
| 1–8 | **Unchanged.** Vault/oracle/pool/Hollar GHO impls/admin transfer/risk-admin grant. |
| 9 (proposal gen) | **Use `tasks/proposals/bil-mainnet-launch.ts`** — to be written, mirrors `heurc-launch.ts` structure, composes the full single-batch shape (existing BIL governance contents + 2-Pool-BIL registration + stableswap creation + Treasury bootstrap). The lark task `bil.ts` is the staged version and is NOT used on mainnet. |
| 10 (dry-run) | **Unchanged.** Verify event log shows zero `ExecutedFailed` / `BatchInterrupted` / `dispatchError` markers across the full block range, AND the new post-execution checks below pass. |
| 11 (gov submission) | **Unchanged** — WhitelistedCaller track, NOT Root. |
| 12 (verification) | **Expanded.** See "Single-batch post-execution verification" below. |
| **13 (zap deploy) — MOVES UP** | **The BILDepositZap must be deployed BEFORE Phase 9** (proposal generation). The mainnet proposal calls `zap.depositAndSupply` from Treasury in step 3 of the bootstrap, so the zap address must be fixed at proposal-build time. Run the existing `deploy-BILDepositZap` task immediately after Phase 7 (admin transfer); use the *mainnet* vault address. |
| 14 (UI bump) | **Unchanged**, plus stablepool address (10055) goes into `constants.ts` alongside the others. UI Phase 5 (instant redeem) is now implemented on lark — only the `STABLESWAP_BIL_ASSET_ID` constant needs flipping from `550n` (lark naming) to `55n` (mainnet naming after the asset rename). See `hydration-ui/BIL-UI-HANDOVER.md` "Phase 5 implementation" for the file-level summary. |

### Pre-flight (additions to the existing checklist)

```bash
# BILDepositZap deployed and constructor max-approve completed
cast call BILDepositZap "HOLLAR()(address)"        # → HOLLAR mainnet address
cast call BILDepositZap "VAULT()(address)"         # → mainnet vault proxy
cast call HOLLAR "allowance(address,address)(uint256)" \
  BILDepositZap MAINNET_VAULT_ADDR                 # → 2^256 − 1

# Treasury can borrow 600K HOLLAR on the main MM
cast call MAIN_POOL "getUserAccountData(address)" TREASURY_ADDR
# availableBorrowsBase (4th return) ≥ 600_000e8

# BILOracleAdapter is reading the right vault and returning sane price
cast call BILOracleAdapter "vault()(address)"           # → mainnet vault proxy
cast call BILOracleAdapter "latestRoundData()(...)"     # answer ≈ 1.0e8 at launch (no yield accrued yet)

# Confirm 2-Pool-BIL asset id is free
polkadot-api:
  assetRegistry.assets(10055)              # → None (asset id is unclaimed)
```

### Single-batch post-execution verification

Run AFTER governance executes, in addition to the existing BIL-side
checks (BIL aToken proxy non-zero, etc.):

```bash
# Stableswap pool exists with the right shape
polkadot-api:
  assetRegistry.assets(10055)              # name="2-Pool-BIL", type=StableSwap
  stableswap.pools(10055)                  # assets=[55, 222]; amplification=100; fee=1000
  stableswap.pegs(10055)                   # peg sources match config
  multiTransactionPayment.acceptedCurrencies(10055)  # is Some

# Treasury bootstrap completed end-to-end
  tokens.accounts(treasury, 10055)         # > 0 (LP shares received)
  cast call MAIN_POOL "getUserAccountData(address)" TREASURY  # totalDebtBase increased by ≈600_000e8

# Pool composition matches what we sent
  tokens.accounts(stableswap-pool-account-addr, 55)   # ≈ 300_000e18 BIL
  tokens.accounts(stableswap-pool-account-addr, 222)  # ≈ 300_000e18 HOLLAR

# Spot-quote sanity: 1 BIL → ≈ 1 HOLLAR (within fee + minor amp curvature)
# via router or direct stableswap call — confirms peg / liquidity is healthy
```

### Lark stablepool dry-run — verified 2026-05-01

`tasks/proposals/bil-stablepool-lark.ts` was dry-run on a chopsticks fork
of lark (twice — first run surfaced lesson 11, second run with the V3
oracle + consolidation step landed clean):

```
=== Failure marker summary ===
  evm.ExecutedFailed:        0
  utility.BatchInterrupted:  0
  system.ExtrinsicFailed:    0
  *** Clean execution — no failure markers ***

=== Post-state ===
  assetRegistry.assets(10055):                       2-Pool-BIL, StableSwap, 18 dec ✓
  multiTransactionPayment.acceptedCurrencies(10055): set ✓
  stableswap.pools(10055):                           assets=[222,550], amp=100, fee=0.10% ✓
  treasury LP (10055):                               599,099.99 LP shares ✓
  treasury aBIL (550, via CurrenciesApi):           896.56 (= safety-buffer dust) ✓
  treasury HOLLAR (222, via CurrenciesApi):          572,464.91 (pre-state preserved) ✓
```

Important querying nuance: `tokens.accounts(treasury, asset)` (orml_tokens
storage) returns 0 for **Erc20-typed** assets (HOLLAR=222, aBIL=550) —
their balances live in the EVM contract storage and aren't tracked in
orml_tokens. Use `CurrenciesApi.account(asset, who)` (substrate runtime
call) to read the real balance via the precompile. The submit script
includes both for diagnostic clarity.

### Anticipated failure modes

- **`scheduleAfter` block-offset too small.** The pool must be created
  *before* Treasury's `addAssetsLiquidity` runs. `scheduleAfter(0, ...)`
  may run in the same block as pool creation, when the pool may not yet
  be queryable. Use `scheduleAfter(1, ...)` minimum (heurc-launch's
  pattern). On dry-run, verify by event order.
- **Treasury insufficient borrow capacity at execution time.** If
  Treasury's main-MM collateral changed between proposal-build and
  execution (rare but possible — interest accrual, parameter changes,
  etc.), the 600K HOLLAR borrow could revert. Pre-flight check covers
  build-time, but a proposal landing weeks after build is at risk.
  Re-verify at submission time.
- **Asset-sort order in `addAssetsLiquidity`.** Stableswap enforces
  ascending asset-id sort. BIL=55 < HOLLAR=222, so the array must be
  `[BIL, HOLLAR]`. Inverted order silently produces wrong pool
  composition. Caught on dry-run by inspecting `tokens.accounts(pool, _)`.
- **`BILOracleAdapter.vault()` mismatch.** If the oracle was deployed
  pointing at the lark vault, peg-source reads will return stale data or
  revert during stableswap operations. Pre-flight check is the gate —
  do NOT skip.
- **`maxPegUpdate=200` too tight if our APY estimate is wrong.** If BIL
  yields drift higher than expected (e.g., a Decentral pool yields
  >50% APR transiently), the cap could throttle peg updates and create
  arb opportunities for stableswap LPs. Mitigation: `stableswap.updatePool`
  call (root-only, but inside dispatcher) can raise the cap post-launch
  without re-running governance from scratch.

## Lark vs mainnet asset id divergence

The existing 0.lark deployment is in the **old naming convention** from
the original BIL launch (handover lesson 10). Renaming on lark via
`assetRegistry.update` is risky because the live Aave BIL pool was
initialized when lark assets were in their original state, and the
precompile→contract mapping is sensitive to changes.

| Asset id | Lark (current) | Mainnet (target / new naming) |
|---|---|---|
| 55 | `BIL` → `0xb82c…548D8` (vault proxy) | `BIL` → aToken proxy (the user-held token) |
| 550 | `aBIL` → `0x9cd4…ada2` (aToken proxy) | `BIL` → vault proxy (underlying) |

**Decision:** leave lark's asset registry alone. The stablepool launch task
(`bil-stablepool-lark.ts`) uses **asset 550** as the BIL-aToken side
because that's what users actually hold on lark. The mainnet variant
(`bil-mainnet-launch.ts`) will use **asset 55** because mainnet starts
in the new naming.

**Implication for the lark UI:** if you want to test the instant-redeem
path on lark after the stablepool deploys, the UI needs to know to route
through asset 550 ↔ 222 (not 55 ↔ 222). Add a network-conditional in the
UI module's stableswap config when wiring Phase 5.

**Implication for mainnet:** the first mainnet rehearsal after this lark
test must use the mainnet asset ids (55 ↔ 222). Don't copy the lark task
verbatim — re-derive the asset ids from the mainnet target naming.

**Sort order on lark:** ascending → `[HOLLAR=222, aBIL=550]`. Pegs follow
the same order: HOLLAR fixed `[1,1]` first, aBIL `MMOracle` second.

**Sort order on mainnet:** ascending → `[BIL=55, HOLLAR=222]`. Pegs:
BIL `MMOracle` first, HOLLAR fixed `[1,1]` second. The previous
"Mainnet single-batch launch composition" section above documents this
correctly — the divergence is a lark-only quirk.

## Pre-flight checklist (MUST pass before step 11)

Run each check before submitting the governance proposal. Do not skip.

```bash
# Admin is correctly transferred to governance precompile
cast call ACLManager-BIL "isPoolAdmin(address)(bool)"     0xaa7e0000000000000000000000000000000aa7e0 # → true
cast call ACLManager-BIL "isRiskAdmin(address)(bool)"     0xaa7e0000000000000000000000000000000aa7e0 # → true
cast call ACLManager-BIL "isEmergencyAdmin(address)(bool)" 0xaa7e0000000000000000000000000000000aa7e0 # → true
cast call PoolAddressesProvider-BIL "getACLAdmin()(address)" # → 0xaa7e...
cast call PoolAddressesProvider-BIL "owner()(address)"      # → 0xaa7e...

# ReservesSetupHelper can configure reserves
cast call ACLManager-BIL "isRiskAdmin(address)(bool)" <ReservesSetupHelper-address> # → true

# BIL OracleAdapter is wired to the right vault (the location used in registry)
cast call BILOracleAdapter "vault()(address)" # → vault proxy address used in the proposal's BIL registration

# All required artifacts present
ls deployments/<network>/HOLLAR.json \
   deployments/<network>/ZeroDiscountRateStrategy.json \
   deployments/<network>/GhoAToken-BIL.json \
   deployments/<network>/GhoStableDebtToken-BIL.json \
   deployments/<network>/GhoVariableDebtToken-BIL.json \
   deployments/<network>/GhoInterestRateStrategy-BIL.json \
   deployments/<network>/Pool-Proxy-BIL.json \
   deployments/<network>/PoolAddressesProvider-BIL.json \
   deployments/<network>/AaveOracle-BIL.json \
   deployments/<network>/ACLManager-BIL.json \
   deployments/<network>/BILOracleAdapter.json

# Market config is filled in
grep -q TODO_DEPLOY markets/bil/index.ts && echo "FAIL: TODOs remaining" || echo "OK"
```

## Governance submission — mainnet flow (WhitelistedCaller, not Root)

Lark used the Root track with a 4B HDX conviction vote from Alice because the
chain is kept deliberately cheap for testing. **Do not use Root on mainnet** —
the DD is prohibitive (1M HDX) and it's not the intended path. Use the
`WhitelistedCaller` track which is exactly what the proposal's `whitelist`
wrapping is designed for.

The flow in `tasks/proposals/bil.ts` generates both forms via
`generateProposalV2(txs, true)`:

- `whitelistedCall` — the inner `utility.batchAll(...)` whose hash the TC
  whitelists.
- `proposal` — the outer `whitelist.dispatchWhitelistedCallWithPreimage(whitelistedCall)`
  which runs on the WhitelistedCaller track.

Submission order on mainnet:

1. A Technical Committee member submits `technicalCommittee.propose(threshold, whitelist.whitelistCall(innerHash), length)`.
   With threshold=1 member, this whitelists immediately. With a multi-member
   TC (mainnet), other members co-sign via `technicalCommittee.vote`.
2. Note the outer proposal preimage: `preimage.notePreimage(proposalHex)`.
3. Submit referendum on WhitelistedCaller track:
   ```
   referenda.submit({ Origins: "WhitelistedCaller" },
                   { Lookup: { hash: proposalHash, len: proposalLen } },
                   { After: 1 })
   ```
4. Place Decision Deposit.
5. Vote aye. WhitelistedCaller track passes with much less conviction than
   Root on mainnet — but still let it run the normal decision period.
6. On approval + enactment, the inner batchAll executes as Root.

The dry-run script at `scripts/submit-bil-proposal.ts` is currently wired for
the lark Root-track shortcut. **For mainnet, switch to the whitelist flow** —
re-instate the TC-propose + WhitelistedCaller submit path (an earlier version
of the script has it; see git history of that file on branch
`feat/bil-market` before commit `[TBD]` for a starting point).

## Dry-run on chopsticks — how to do it correctly

Chopsticks forks the full chain state (substrate + EVM) and lets us simulate
the governance flow locally before touching mainnet.

```bash
npx @acala-network/chopsticks \
  --endpoint wss://rpc.hydradx.cloud \
  --port 8000 \
  --mock-signature-host \
  --build-block-mode Instant
```

On the chopsticks fork:
1. **Before anything:** run `transfer-bil-admin-to-governance.ts` +
   `grant-bil-risk-admin.ts`. Even on the fork. Skipping these is what made
   the ref-322 disaster unobservable.
2. Use the chopsticks-mode branch of the submit script (auto-detects localhost).
3. **After execution, count failure markers in the FULL event range:**
   ```
   grep -c "ExecutedFailed"          <scan output>
   grep -c "BatchInterrupted"        <scan output>
   grep -c "dispatchError"           <scan output>
   grep -c "{\"err\""                <scan output>
   ```
   All four counts must be **0**. Do not trust `utility.BatchCompleted` alone —
   `dispatcher.dispatchAsAaveManager` returns `{Ok: ...}` at the outer level
   even when the inner EVM call hit `evm.ExecutedFailed`. The `BatchCompleted`
   event fires regardless.

4. **Verify post-state on chopsticks:**
   ```
   cast call Pool-Proxy-BIL "getReservesList()(address[])"  # [BIL, HOLLAR]
   cast call Pool-Proxy-BIL "getReserveData(...)" BIL       # aToken != 0x0
   cast call Pool-Proxy-BIL "getReserveData(...)" HOLLAR     # aToken != 0x0
   cast call HOLLAR "getFacilitator(address)(...)" <predicted-GhoAToken>
                                                              # bucketCapacity == 1e24
   ```

## Key differences: 0.lark → mainnet

| Concern | 0.lark | Mainnet |
|---|---|---|
| TC members | Just Alice (`//Alice`) | Real multisig with multiple members |
| Submitter | Alice signs `//Alice` | Real TC-member signer (hardware wallet / multisig) |
| Governance track | Root (fast, 4B HDX) | **WhitelistedCaller** (designed path) |
| Decision Deposit | 1M HDX on Root | Configured per track (check `referenda.tracks` const) |
| Preimage deposit | small | Larger; confirm signer has HDX |
| Conviction lock | Multi-month even on lark | Multi-month; vote carefully |
| Contracts at fixed addrs (HOLLAR, GhoOracle, etc.) | Same as mainnet (fork) | Canonical |
| `aa7e...` precompile | Same | Same |
| **Launch shape** | **Staged: BIL pool first, zap separately, stableswap deferred** | **Single-batch: vault + pool + governance + zap + stableswap + Treasury bootstrap, all in one referendum.** See "Mainnet single-batch launch composition" above. |
| **Stableswap pool** | Not deployed (still unbuilt as of writing) | 2-Pool-BIL (10055), BIL/HOLLAR pair, amp=100, fee=0.1%, peg via existing BILOracleAdapter, maxPegUpdate=200 |
| **Initial liquidity** | None | Treasury borrows 600K HOLLAR from main MM; pairs 300K HOLLAR + 300K BIL into the new pool; resulting LP shares stay in Treasury as protocol-owned liquidity |

## What went wrong on 0.lark — and how to avoid it

Full transparency for future handovers.

### 1. Admin transfer was missed (cost: ref 322 bricked — recovery via ref 323/324)

When porting fixes from Yash's `ys-gigahdx` branch, I flagged
`scripts/transfer-admin-to-governance.ts` as "likely needed post-deploy" but
then classified it as informational and didn't port it. By the time we hit
governance, the proposal submitted successfully, but every EVM call inside the
batchAll hit `evm.ExecutedFailed` because `dispatcher.dispatchAsAaveManager`
set the EVM caller to `0xaa7e...` which was NOT a pool admin. The dispatcher
returned `{Ok: ...}` despite the inner failure, and `utility.BatchCompleted`
fired — so the surface signals all looked clean.

**Fix:** `scripts/transfer-bil-admin-to-governance.ts` is now committed. It's
step 7 above. **Do not skip.** Run it on any network BEFORE the governance
proposal.

### 2. Dry-run event log was only skimmed (cost: false confidence in chopsticks)

When I ran the dry-run on chopsticks, I only looked at the tail of the event
output. The tail showed `evm.Executed` (on HOLLAR + the cross-reference calls
to pre-existing contracts), `assetRegistry.Registered`, and
`utility.BatchCompleted`. The first ~30 events — 7 `evm.ExecutedFailed`
entries — were scrolled off screen. I declared success. The real chain
replay failed identically, because chopsticks had the same pool admin
situation.

**Fix:** After any on-chain simulation, explicitly grep for
`ExecutedFailed` / `BatchInterrupted` / `dispatchError` across the full
execution block range. Do not trust surface events. Verify expected state via
direct `cast call` on the deployed contracts.

### 3. Idempotency was incomplete (cost: ref 323 reverted)

After the ref-322 failure, I tried to re-submit. The asset-registry
`.register` calls were already idempotent (skip if `isSome`), but the
`multiTransactionPayment.addCurrency` calls were not — ref 322 already added
BIL/aBIL as fee currencies, so the re-submit reverted with
`AlreadyAccepted`, which is a batch-level revert in `batchAll`. Same for
`HOLLAR.addFacilitator` — already added on ref 322, re-call would revert.

**Fix:** `tasks/proposals/bil.ts` now has idempotency guards for all
four potentially-duplicated calls:
- `assetRegistry.register(BIL, ...)` — skip if `isSome`
- `assetRegistry.register(aBIL, ...)` — skip if `isSome`, emit update if location drifted
- `multiTransactionPayment.addCurrency(BIL)` — skip if `acceptedCurrencies(55).isSome`
- `multiTransactionPayment.addCurrency(aBIL)` — skip if `acceptedCurrencies(550).isSome`
- `HOLLAR.addFacilitator(ghoAToken)` — skip if `getFacilitator(addr).bucketCapacity > 0`

This means re-submitting a proposal after a partial failure is safe.

### 4. Missed artifact copies (cost: minor — 2 re-runs)

`HOLLAR.json` and `ZeroDiscountRateStrategy.json` are referenced by the
proposal task (`hre.deployments.get(...)`) but weren't in
`deployments/lark/`. They exist on mainnet and on lark (forked state), just
needed to be copied from `deployments/hydration/` / `hollar/deployments/hydration/`.

**Fix:** Step 6 of the phase ordering now lists them explicitly. The
pre-flight checklist verifies they're present.

### 5. Forgot Alice's frozen balance on lark (cost: 30 min debug)

On the 0.lark fork, Alice had 4.5B HDX but all of it was locked by prior
conviction-voting locks (`pyconvot`). This meant she couldn't pay a
Submission Deposit. On lark we worked around this with
`scripts/unlock-alice-votes.ts` (removing her votes on resolved refs, then
`unlock`). On mainnet, the signer must have sufficient liquid HDX for all
deposits — verify via `acc.data.free - acc.data.frozen > required` before
submission.

### 6. Nonce-offset prediction logic (no loss — pre-validated)

`tasks/proposals/bil.ts` already has the nonce-offset detection (Yash's fix)
that handles both "BIL reserve pre-initialized" and "BIL reserve to be
initialized in this batch" cases. It queries `pool.getReservesList()` and
adjusts the predicted GhoAToken proxy address accordingly. On mainnet this
will correctly predict offset 3 (BIL not initialized until the proposal).

### 7. BIL registered as Token instead of Erc20 (cost: lark needs remediation; mainnet code now correct)

The original proposal task copied Yash's GIGAHDX pattern verbatim:
`assetType: "Token"` with `location: null` for the underlying collateral.
That's correct for stHDX (a substrate-native asset with no EVM contract) but
wrong for BIL — BIL *is* an EVM contract (the vault). When registered as
`Token`, the substrate→EVM precompile at `tokenAddress(55)` does not bridge
to the actual vault contract, so `Pool.supply(BIL, amount)` reverts on its
internal `transferFrom` call.

**Fix:** `tasks/proposals/bil.ts` now registers BIL as
`assetType: "Erc20"` with `location: location(vault_proxy)`, where
`vault_proxy` is read at proposal-build time from
`BILOracleAdapter.vault()` (so it works on any network without
hardcoding). The aBIL registration was always correct (`Erc20` →
BIL aToken proxy).

The 0.lark deployment will need a remediation `assetRegistry.update(55, ...)`
to switch type/location — handled separately from this code change.

### 8. Forgot to approve Pool-Proxy-BIL for managed-balance access (cost: every user would need a separate approve before supplying)

Hydration's EVM has a managed-contract approval mechanism: contracts in
`EVMAccounts.ApprovedContract` can call `transferFrom` on substrate-mapped
tokens without requiring an explicit `IERC20.approve` from the user. This is
how the existing money-market avoids the two-tx UX. We forgot to add the
BIL Pool-Proxy to this list in the original proposal.

**Fix:** the proposal task now appends
`EVMAccounts.approve_contract(Pool-Proxy-BIL)` to the substrate phase, with
an idempotency check on `EVMAccounts.ApprovedContract` storage so re-runs
don't revert.

### 9. `Utility.batch_all([vault.deposit, pool.supply])` is not actually atomic across EVM reverts (cost: dust accumulation + intermittent partial-state failures on lark)

The first version of the UI's `useDeposit` ran a substrate `Utility.batch_all`
of three EVM extrinsics: `HOLLAR.approve(vault)` → `vault.deposit(amount)` →
`pool.supply(precompile, predictedBil, user, 0)`, where `predictedBil` came
from an off-chain `vault.previewDeposit(amount)` read just before submission.

Two failure modes:

1. **Drift between `previewDeposit` read and `vault.deposit` execution.** Yield
   accrues every block, so by the time the batch lands, the actual mint comes
   out a few wei smaller than `predictedBil`. `pool.supply(predictedBil)`
   then reverts because the user has slightly less than predicted.

2. **`Utility.batch_all` is atomic at the substrate dispatch level, not at the
   EVM-execution level.** A `pallet_evm.call` extrinsic that hits an internal
   EVM revert *still returns `Ok` at the substrate level* — the runtime emits
   `evm.ExecutedFailed` as an event and considers the dispatch successful.
   So `batch_all` happily proceeds past a reverted EVM call, leaving the
   user with `vault.deposit` committed (BIL minted to wallet) and
   `pool.supply` reverted (no aBIL minted). This is the same trap as
   `dispatcher.dispatchAsAaveManager` returning `Ok` despite inner EVM
   failure (lesson 1) — except here it's `pallet_evm.call` directly, not the
   dispatcher.

We tried percentage-based safety buffers on `predictedBil` (subtract 0.001%
to absorb drift) but the dust scaled with deposit size: a 222k HOLLAR deposit
left ~2.2 BIL behind per batch, which adds up.

**Fix:** `BILDepositZap.sol` (lesson moved into the Components section
above). The zap reads the actual `vault.deposit` return value on-chain and
passes it straight to `pool.supply` in the same transaction — no
prediction, no dust, fully atomic at the EVM level (a revert anywhere
reverts the whole tx). The UI's `useDeposit` now batches:

```
HOLLAR.approve(zap, hollarAmount)      // only if allowance < amount
zap.depositAndSupply(hollarAmount)
```

The first call is still a separate substrate extrinsic (different target
contract), but it's an idempotent state-only update — there's no EVM-revert
trap because there's nothing inside HOLLAR.approve that can revert
silently. The second call is a single EVM extrinsic, atomic by EVM
semantics.

### 12. Stablepool launch needs `router.forceInsertRoute` calls for fee-payment conversion (cost: one follow-up proposal on lark)

After the lark stablepool launch landed cleanly (chain state perfect —
asset 10055 registered, pool created with right pegs, Treasury holding
599K LP shares), the pool was missing from the UI's liquidity tab and
the wallet's LP balance display. **That turned out to be a stale browser
cache** — a hard refresh resolved both. The asset list IS picked up by
the SDK once the cache clears; routes weren't relevant to UI visibility.

What routes ARE needed for: **fee-payment conversion**. Hydration's
`multiTransactionPayment` lets users pay fees in any accepted currency
(H2O, WETH, ETH, etc.). The router uses `router.routes` entries to
convert those fee assets into whatever the operation's native asset is.
Without routes from H2O/WETH to BIL, users can hold and trade BIL
fine, but **they can't pay fees in H2O / WETH while interacting with
BIL surfaces** — the conversion step has no path.

The pattern from `hollar-pools-launch.ts` and `gigaeth-launch.ts`: each
launch registers ≥1 `router.forceInsertRoute` call. Routes use the new
pool as a hop, ending at the user-held asset (aToken).

I missed this in `bil-stablepool-lark.ts` and shipped a separate
follow-up batch (`scripts/submit-bil-routes-lark.mjs`) with two routes:
`H2O→BIL` and `WETH→BIL`. The mainnet launch should bundle the
forceInsertRoute calls into the same single-batch proposal so there's
no follow-up needed — see "Router routes" subsection above for the
exact route templates.

Routes between assets that are already in the same pool (e.g. HOLLAR↔BIL)
are NOT needed — the router infers swap paths through pool membership.
You only need routes from "external" fee-currency assets to the
user-held asset.

### 11. BILOracleAdapter needed Chainlink V3 interface for stableswap MMOracle (cost: one chopsticks dry-run + a re-deploy on lark)

The original `BILOracleAdapter.sol` implemented only Aave's
`IEACAggregatorProxy` interface — `latestAnswer` / `latestTimestamp` /
`latestRound` / `getAnswer` / `getTimestamp`. That's all Aave's AaveOracle
calls, so the BIL Aave pool worked fine.

But Hydration's stableswap pallet's `MMOracle` peg-source resolver calls
the **modern Chainlink V3 `AggregatorV3Interface`** —
specifically `latestRoundData()`. When the resolver hit our adapter, it
reverted (no fallback function), and the pallet surfaced
`Stableswap::MissingTargetPegOracle` (Module index 70, error 25).

I caught this on the first chopsticks dry-run of `bil-stablepool-lark.ts`:
the Root referendum approved cleanly but the scheduled batch dispatch at
the enactment block failed with `Module(70, 0x19000000)`. Decoding that
against chain metadata showed `Stableswap::MissingTargetPegOracle`.
Comparing the existing gigaeth pool's MMOracle (`0xaafd75…`, working) to
BILOracleAdapter (failing) showed the working oracle returns valid data
for `latestRoundData()` while ours reverted.

**Fix:** added the full Chainlink V3 surface to BILOracleAdapter
(`description`, `version`, `getRoundData`, `latestRoundData`) — backward
compatible with the existing Aave usage. Re-deployed on lark, got new
address `0x90a6B6357bA5925e730657813173C4B1a9af8346`. The stablepool
launch proposal now also includes a `dispatcher.dispatchAsAaveManager`
call to re-point the BIL pool's AaveOracle source to the new oracle —
so lark ends up with one consolidated oracle instead of two.

**For mainnet:** deploy the V3-compliant BILOracleAdapter from the start.
No consolidation step needed because mainnet starts with one oracle.

### 10. Asset-id naming flipped after launch (no cost — caught before mainnet)

The original deploy registered the user-held aToken at asset 550 as `aBIL`
and the underlying vault token at asset 55 as `BIL`. After 0.lark execution
we flipped to: **asset 55 = `BIL`** (the aToken users hold post-auto-deposit)
and **asset 550 = `BIL`** (the underlying). The flip mirrors the GDOT pattern
and reflects the actual UX flow — the UI auto-supplies the vault token (BIL)
into the Aave pool right after the user's HOLLAR→BIL deposit, so the
durable user balance is the aToken (BIL), not the underlying.

**Fix on lark:** update both registry entries via `assetRegistry.update` on a
follow-up proposal (handled separately from this code change). **Mainnet:**
the proposal task in this branch produces the correct naming on first run —
asset 55 registers as BIL → BIL aToken proxy, asset 550 registers as BIL →
vault proxy.

## 0.lark deployed addresses (reference)

| Component | 0.lark Address |
|---|---|
| BIL Vault proxy | `0xB82cF8A62EB1b51a2f2A9d71C120E2fB8ae548D8` |
| BIL Vault impl | `0x6E60c3bc3f43f71E5A5CDa929088fBa13b4102dc` |
| BILOracleAdapter (legacy, V1 — used by BIL pool's AaveOracle until re-pointed by the stablepool launch proposal) | `0x19Cb1536947bA792d71c04F4dBa9DcDF63C840A7` |
| BILOracleAdapter (V3 — re-deployed 2026-05-01 with Chainlink V3 interface; used by stablepool MMOracle peg AND consolidated as the BIL pool's source) | `0x90a6B6357bA5925e730657813173C4B1a9af8346` |
| BILDepositZap | `0x75d09AbAF2005b0ba06abE6a49796D0180D9a375` |
| PoolAddressesProvider-BIL | `0xB0fa53A6cBaF88eDD90aD27a6c396D99d272FE64` |
| Pool-Proxy-BIL | `0x7d78C0d9c8F6635b2bc481b674bd74E2917392e8` |
| PoolConfigurator-Proxy-BIL | `0x4e7f9e8AEaC72938254e5520B2428dD75517C6F9` |
| AaveOracle-BIL | `0x19Cb1536947bA792d71c04F4dBa9DcDF63C840A7` (same as OracleAdapter — coincidence of deployer-nonce across two separate deploys) |
| ACLManager-BIL | `0x68F38AeF16B6E197Bb0C86B15fDACFC461074D04` |
| AToken-BIL (impl) | `0x75677FC81cFd0577bfd9442CCaf5D6C88e44836d` |
| AToken-BIL (proxy for BIL reserve — bound to asset 55 `BIL`) | `0x9cd4410c27977CD5e400e43B7B1aB5ADD845ada2` |
| GhoAToken-BIL (impl) | `0xa67f4FB7E691414cf064aE432F3e647601e36207` |
| GhoAToken-BIL (proxy for HOLLAR reserve) | `0x8936D09C63830062FAd22C1Eb9ED37Bc12a4659a` |
| GhoVariableDebtToken-BIL (proxy) | `0x27633213BE89A725a25B9e4F49c5E514f6790eb3` |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` (forked from mainnet) |
| HOLLAR | `0x531a654d1696ED52e7275A8cede955E82620f99a` (mainnet constant) |
| GhoOracle (for HOLLAR) | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (mainnet constant) |
| Aave manager precompile | `0xaa7e0000000000000000000000000000000aa7e0` (Hydration constant) |

Mainnet addresses will differ for the BIL-specific contracts; HOLLAR, GhoOracle, and the aa7e precompile are canonical and identical.

## Scripts reference

All under `scripts/` and `tasks/misc/` (or `tasks/proposals/`):
- `tasks/misc/deploy-BILOracleAdapter.ts` — Phase 2.
- `tasks/misc/deploy-BILDepositZap.ts` — On mainnet runs **before** proposal generation (so the proposal can reference the zap address). On lark this was Phase 13 (post-execution). Atomic deposit+supply helper.
- `tasks/proposals/bil.ts` — **Lark only.** First-stage launch: BIL pool + governance config. Already executed on lark.
- `tasks/proposals/bil-stablepool-lark.ts` — **Lark only.** Second-stage launch: 2-Pool-BIL asset + stableswap pool + Treasury liquidity bootstrap (full borrow + deposit + add-liquidity flow). Run AFTER `bil.ts` and AFTER `BILDepositZap` is deployed. Submitted via Root track (non-urgent). Treasury bootstrap uses `dispatchAs(treasury, evm.call(...))` for the borrow + approve + zap.depositAndSupply EVM calls — this pattern is unprecedented in this repo (heurc/giga* all use substrate-only Treasury calls), so dry-run carefully on chopsticks before lark submission. **Uses asset 550 (`aBIL` under lark's old naming) for the stablepool's BIL side**, NOT asset 55 — see "Lark vs mainnet asset id divergence" below.
- `tasks/proposals/bil-mainnet-launch.ts` — **Mainnet only. To be written**, mirroring `heurc-launch.ts`. Composes the full single-batch shape per "Mainnet single-batch launch composition" above. Combines what `bil.ts` and `bil-stablepool-lark.ts` do across two stages on lark, plus the Treasury borrow step.
- `submit-bil-proposal.ts` — generates + submits the **original** BIL launch proposal (vault + Aave pool + governance config). *Currently configured for lark Root-track; for mainnet, switch back to the WhitelistedCaller flow (see "Governance submission" above) AND point at `bil-mainnet-launch` task.*
- `submit-bil-stablepool-lark.ts` — submits the lark stablepool launch proposal (`bil-stablepool-lark` task) end-to-end. Defaults to chopsticks (`PROPOSAL_WS=ws://localhost:8000`); set `PROPOSAL_WS=wss://0.lark.hydration.cloud` to run against live lark. Reads BIL state via `RPC=https://0.lark.hydration.cloud` for the proposal build (chopsticks doesn't expose `eth_call`/`net_version`, so the build step needs the live lark RPC; submission still goes to chopsticks for the dry-run).
- `submit-bil-routes-lark.mjs` — **lark-only follow-up.** Builds + submits a Root proposal that registers `router.forceInsertRoute` calls for `H2O→BIL(550)` and `WETH→BIL(550)` (lesson 12). Standalone @polkadot/api script, no hardhat. **NOT needed on mainnet** — the route inserts will be in the unified `bil-mainnet-launch.ts` proposal task per "Router routes" in the launch composition section.
- `transfer-bil-admin-to-governance.ts` — Phase 7. Idempotent.
- `grant-bil-risk-admin.ts` — Phase 8. Idempotent.
- `unlock-alice-votes.ts` — 0.lark-specific cleanup only. Not relevant on mainnet.

## Network config

All three hydration-family networks are configured in
`helpers/hardhat-config-helpers.ts`:

- `hydration` — mainnet (`https://rpc.hydradx.cloud`). Committable deployments at `deployments/hydration/`.
- `lark` — 0.lark (`https://0.lark.hydration.cloud`). Committable deployments at `deployments/lark/`.
- `chopsticks` — local fork (`http://localhost:8000`). Gitignored at `deployments/chopsticks/`.

Usage:
```
HARDHAT_NETWORK=<network> MARKET_NAME=BIL npx hardhat ...
```

## Post-deploy verification (mainnet)

After mainnet governance execution, run:

```bash
# 1. Event scan — MUST show 0 failure markers
node scripts/scan-mainnet-execution.ts <fromBlock> <toBlock>  # (write if not present)

# 2. Pool state checks
cast call <Pool-Proxy-BIL> "getReservesList()(address[])"   # [BIL, HOLLAR]
cast call <Pool-Proxy-BIL> "getReserveData(address)(...)" <BIL-address>
cast call <Pool-Proxy-BIL> "getReserveData(address)(...)" <HOLLAR-address>

# 3. Facilitator
cast call <HOLLAR> "getFacilitator(address)(uint128,uint128,string)" <predicted-GhoAToken>

# 4. Substrate state
polkadot-api:
  assetRegistry.assets(550)             # name=BIL,  type=Erc20, location=AccountKey20(vault proxy)
  assetRegistry.assets(55)              # name=BIL, type=Erc20, location=AccountKey20(BIL aToken proxy)
  assetRegistry.assetLocations(550)     # decodes to vault proxy
  assetRegistry.assetLocations(55)      # decodes to BIL aToken proxy
  multiTransactionPayment.acceptedCurrencies(550)       # is some  (BIL)
  multiTransactionPayment.acceptedCurrencies(55)        # is some  (BIL)
  EVMAccounts.approvedContract(<Pool-Proxy-BIL>)       # is some

# 5. End-to-end UX check — supply with NO approve()
   In a fresh wallet that's never interacted with the pool:
   - deposit HOLLAR → vault → receive BIL (single tx)
   - directly call pool.supply(BIL, amount) WITHOUT first calling
     IERC20(BIL).approve(pool, ...) — this should succeed because the pool
     is in EVMAccounts.ApprovedContract.
   - borrow HOLLAR
   - repay HOLLAR (also without explicit approve)
   - withdraw BIL
   - redeem BIL → HOLLAR via vault

# 6. Zap end-to-end check — single-tx deposit
   In a fresh wallet:
   - HOLLAR.approve(zap, amount)               # one-time ERC20 approve to zap
   - zap.depositAndSupply(amount)              # atomic deposit + supply
   - Verify: aToken.balanceOf(user) increased by ≈ amount × exchangeRate
   - Verify: vault.balanceOf(user) == 0        # no dust left in user wallet
   - Verify: HOLLAR.balanceOf(zap) == 0        # zap holds nothing between calls
   - Verify: vault.balanceOf(zap) == 0         # zap holds nothing between calls

# 6. End-to-end UI test (on mainnet vault URL)
   deposit HOLLAR → get BIL → supply BIL as collateral → borrow HOLLAR → repay → withdraw
```
