# HDCL Mainnet Deployment Handover

This document is the authoritative runbook for launching the HDCL Aave V3
instance on Hydration mainnet. It supersedes the earlier `HDCL-DEPLOYMENT.md`
phase plan — that one had phases 3 and 4 in the wrong order and missed the
admin-transfer step, both of which bit us hard on 0.lark.

**Status at time of writing (2026-04-23):** HDCL launched successfully on
0.lark after multiple recovery runs. Ref 324 on 0.lark was the clean
execution. All addresses + artifacts captured in `deployments/lark/`.

## Components and naming

The substrate-side asset names are **not** the same as the EVM contract
names — what users see in their wallet is dictated by the assetRegistry, not
the underlying contract's `symbol()`. The naming is intentional:

| Asset id | Registry name | What it is | Location target | Why users see it |
|---|---|---|---|---|
| 550 | **DCL** | Vault token (`HDCLVault.sol`). The user-deposits-HOLLAR-gets-this thing. | vault proxy | Brief — the UI auto-supplies DCL into the Aave pool, so users hold it for milliseconds at most. |
| 55 | **HDCL** | aToken receipt for the DCL reserve in the Aave pool. | DCL aToken proxy | This is what users actually hold. Their balance grows as the pool earns yield. |

This mirrors the GDOT pattern — the user-facing token has the marketed name
(HDCL), the underlying that the auto-deposit unwraps into has its own name
(DCL).

Components:

- **HDCL Vault** — `aave-v3-deploy/hdcl-vault/` (Foundry). Users deposit
  HOLLAR, get DCL vault shares (asset 550), vault deploys HOLLAR into
  Decentral. The UI then auto-supplies DCL into the HDCL Aave pool to mint
  HDCL aToken (asset 55) to the user.
- **HDCLOracleAdapter** — `aave-v3-deploy/contracts/HDCLOracleAdapter.sol`.
  Chainlink-compat (IEACAggregatorProxy) wrapper reading `vault.exchangeRate()`,
  scaled 18→8 decimals. Consumed by Aave's AaveOracle as the price source for
  the DCL reserve.
- **HDCL Aave pool** — separate Aave V3 instance. ProviderId `22222255`. DCL
  supply-only collateral, HOLLAR borrow-only (via GhoAToken facilitator).
- **HOLLAR GHO impls** — per-pool HDCL-specific versions of `GhoAToken-HDCL`,
  `GhoStableDebtToken-HDCL`, `GhoVariableDebtToken-HDCL`,
  `GhoInterestRateStrategy-HDCL` (fixed 10% APR). Built in the `hollar` repo.
  Naming follows the pool name (`HDCL`), not the asset name.
- **Governance proposal** — single `batchAll` containing init-reserve + config
  calls (EVM, via `dispatcher.dispatchAsAaveManager`) plus substrate
  `assetRegistry.register`, `multiTransactionPayment.addCurrency`, and
  `EVMAccounts.approve_contract(Pool-Proxy-HDCL)` calls.

## Correct phase ordering

1. **Deploy HDCL Vault** (Foundry, direct EVM deploy)
2. **Deploy HDCLOracleAdapter** (hardhat task `deploy-HDCLOracleAdapter`, constructor takes vault proxy)
3. **Wire oracle address into market config** — `markets/hdcl/index.ts`
   `ChainlinkAggregator[<network>].HDCL`
4. **Deploy Aave pool infrastructure** (`npm run deploy -- --tags market`).
   Reserve init is deferred (asset precompile not responsive yet) — the
   skip-guard in `09_init_reserves.ts` handles this.
5. **Deploy HOLLAR GHO impls** — in the `hollar` repo, tag `hdcl_hollar_deploy`.
6. **Copy GHO + HOLLAR artifacts** from `hollar/deployments/<network>/` → 
   `aave-v3-deploy/deployments/<network>/`. Also needed:
   - `HOLLAR.json` (the HOLLAR token artifact — pre-existing on mainnet)
   - `ZeroDiscountRateStrategy.json` (pre-existing on mainnet)
7. **CRITICAL: Transfer admin to governance precompile**.
   Run `scripts/transfer-hdcl-admin-to-governance.ts`. This grants
   `DEFAULT_ADMIN_ROLE` / `POOL_ADMIN` / `RISK_ADMIN` / `EMERGENCY_ADMIN` on
   `ACLManager-HDCL` to `0xaa7e0000000000000000000000000000000aa7e0` and
   transfers `PoolAddressesProvider-HDCL` ACL-admin + ownership to it.
   **Without this step the governance proposal dispatches EVM calls as
   `0xaa7e...` but `0xaa7e...` isn't a pool admin, so every call silently
   reverts inside the dispatcher.**
8. **Grant RISK_ADMIN to ReservesSetupHelper** — run
   `scripts/grant-hdcl-risk-admin.ts`. Required for the `configureReserves`
   call inside the proposal's Phase A.
9. **Generate governance proposal** (`npx hardhat hdcl`). Inspect the
   decoded call tree.
10. **Dry-run on chopsticks** (see "Dry-run" section below).
11. **Submit on mainnet governance** (WhitelistedCaller track, NOT Root — see
    "Governance submission" below).
12. **Verify** with full event log scan + pool state queries.
13. **UI update** — bump vault/pool/oracle addresses in
    `hydration-ui/apps/main/src/modules/hdcl-vault/constants.ts` and any
    money-market pool registry.

## What the proposal `batchAll` does (current source of truth)

The HDCL governance proposal task at `tasks/proposals/hdcl.ts` builds these
calls. Every substrate call is idempotent — re-submission after a partial
failure is safe.

**Phase A — DCL collateral reserve (EVM via dispatchAsAaveManager):**
- `init-reserve DCL` → `pool.initReserves(...)` for the DCL underlying
  (asset 550 / vault token) with the standard AToken / StableDebtToken /
  VariableDebtToken impls and `rateStrategyStables`. The aToken proxy this
  creates is the address the substrate registry binds to "HDCL" (asset 55)
  in Phase D.
- `configureReserves` → applies LTV 70 / LiqThresh 80 / liquidation bonus 7% /
  reserve factor 20% / supply cap 3M / borrow disabled / debt ceiling 0.
- `setupLiquidationProtocolFee` → 10%.

**Phase B — HOLLAR borrow reserve (EVM via dispatchAsAaveManager):**
- `pool.initReserves` for HOLLAR using the HDCL-specific `GhoAToken-HDCL` /
  `GhoStableDebtToken-HDCL` / `GhoVariableDebtToken-HDCL` impls and
  `GhoInterestRateStrategy-HDCL` (fixed 10% APR).
- `setReserveBorrowing(HOLLAR, true)`.
- `AaveOracle-HDCL.setAssetSources([HOLLAR], [GhoOracle])`.

**Phase C — HOLLAR facilitator + GHO cross-references (EVM via dispatchAsAaveManager):**
- `HOLLAR.addFacilitator(predictedGhoAToken, "HDCL", 1M HOLLAR)` — *skipped if
  bucket already set up*.
- `GhoAToken.setVariableDebtToken(predictedGhoVariableDebt)`.
- `GhoAToken.updateGhoTreasury(treasury)`.
- `GhoVariableDebt.setAToken(predictedGhoAToken)`.
- `GhoVariableDebt.updateDiscountRateStrategy(ZeroDiscountRateStrategy)`.
- `GhoVariableDebt.updateDiscountToken(HOLLAR)`.

The predicted addresses use a nonce-offset that auto-detects whether HDCL is
already initialized (offset 0) or being initialized in this batch (offset 3).

**Phase D — Substrate (root):**
- `assetRegistry.register(550, **DCL**, Erc20, location → vault proxy)` —
  the underlying vault token. Skipped if already registered; if location
  drifted, emits `assetRegistry.update`.
- `assetRegistry.register(55, **HDCL**, Erc20, location → DCL aToken proxy)`
  — the user-facing aToken receipt. Same idempotency.
- `multiTransactionPayment.addCurrency(550, HOLLAR_price)` — DCL accepted
  for fees. Skipped if already accepted.
- `multiTransactionPayment.addCurrency(55, HOLLAR_price)` — HDCL accepted
  for fees. Skipped if already accepted.
- `EVMAccounts.approve_contract(Pool-Proxy-HDCL)` — adds the pool to
  Hydration's managed-balance approved-contract list so users don't need a
  separate `IERC20.approve(pool, ...)` before `pool.supply`. Idempotent.

The vault proxy address used for DCL's `location` is read at proposal-build
time from the on-chain `HDCLOracleAdapter.vault()` getter, so it's correct on
any network without hardcoding. The DCL aToken proxy address used for HDCL's
`location` is computed from PoolConfigurator's nonce (offset 0 if DCL reserve
is already initialized, else current nonce — see Phase C nonce-prediction).

## Pre-flight checklist (MUST pass before step 11)

Run each check before submitting the governance proposal. Do not skip.

```bash
# Admin is correctly transferred to governance precompile
cast call ACLManager-HDCL "isPoolAdmin(address)(bool)"     0xaa7e0000000000000000000000000000000aa7e0 # → true
cast call ACLManager-HDCL "isRiskAdmin(address)(bool)"     0xaa7e0000000000000000000000000000000aa7e0 # → true
cast call ACLManager-HDCL "isEmergencyAdmin(address)(bool)" 0xaa7e0000000000000000000000000000000aa7e0 # → true
cast call PoolAddressesProvider-HDCL "getACLAdmin()(address)" # → 0xaa7e...
cast call PoolAddressesProvider-HDCL "owner()(address)"      # → 0xaa7e...

# ReservesSetupHelper can configure reserves
cast call ACLManager-HDCL "isRiskAdmin(address)(bool)" <ReservesSetupHelper-address> # → true

# HDCL OracleAdapter is wired to the right vault (the location used in registry)
cast call HDCLOracleAdapter "vault()(address)" # → vault proxy address used in the proposal's HDCL registration

# All required artifacts present
ls deployments/<network>/HOLLAR.json \
   deployments/<network>/ZeroDiscountRateStrategy.json \
   deployments/<network>/GhoAToken-HDCL.json \
   deployments/<network>/GhoStableDebtToken-HDCL.json \
   deployments/<network>/GhoVariableDebtToken-HDCL.json \
   deployments/<network>/GhoInterestRateStrategy-HDCL.json \
   deployments/<network>/Pool-Proxy-HDCL.json \
   deployments/<network>/PoolAddressesProvider-HDCL.json \
   deployments/<network>/AaveOracle-HDCL.json \
   deployments/<network>/ACLManager-HDCL.json \
   deployments/<network>/HDCLOracleAdapter.json

# Market config is filled in
grep -q TODO_DEPLOY markets/hdcl/index.ts && echo "FAIL: TODOs remaining" || echo "OK"
```

## Governance submission — mainnet flow (WhitelistedCaller, not Root)

Lark used the Root track with a 4B HDX conviction vote from Alice because the
chain is kept deliberately cheap for testing. **Do not use Root on mainnet** —
the DD is prohibitive (1M HDX) and it's not the intended path. Use the
`WhitelistedCaller` track which is exactly what the proposal's `whitelist`
wrapping is designed for.

The flow in `tasks/proposals/hdcl.ts` generates both forms via
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

The dry-run script at `scripts/submit-hdcl-proposal.ts` is currently wired for
the lark Root-track shortcut. **For mainnet, switch to the whitelist flow** —
re-instate the TC-propose + WhitelistedCaller submit path (an earlier version
of the script has it; see git history of that file on branch
`feat/hdcl-market` before commit `[TBD]` for a starting point).

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
1. **Before anything:** run `transfer-hdcl-admin-to-governance.ts` +
   `grant-hdcl-risk-admin.ts`. Even on the fork. Skipping these is what made
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
   cast call Pool-Proxy-HDCL "getReservesList()(address[])"  # [HDCL, HOLLAR]
   cast call Pool-Proxy-HDCL "getReserveData(...)" HDCL       # aToken != 0x0
   cast call Pool-Proxy-HDCL "getReserveData(...)" HOLLAR     # aToken != 0x0
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

**Fix:** `scripts/transfer-hdcl-admin-to-governance.ts` is now committed. It's
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
HDCL/aHDCL as fee currencies, so the re-submit reverted with
`AlreadyAccepted`, which is a batch-level revert in `batchAll`. Same for
`HOLLAR.addFacilitator` — already added on ref 322, re-call would revert.

**Fix:** `tasks/proposals/hdcl.ts` now has idempotency guards for all
four potentially-duplicated calls:
- `assetRegistry.register(HDCL, ...)` — skip if `isSome`
- `assetRegistry.register(aHDCL, ...)` — skip if `isSome`, emit update if location drifted
- `multiTransactionPayment.addCurrency(HDCL)` — skip if `acceptedCurrencies(55).isSome`
- `multiTransactionPayment.addCurrency(aHDCL)` — skip if `acceptedCurrencies(550).isSome`
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

`tasks/proposals/hdcl.ts` already has the nonce-offset detection (Yash's fix)
that handles both "HDCL reserve pre-initialized" and "HDCL reserve to be
initialized in this batch" cases. It queries `pool.getReservesList()` and
adjusts the predicted GhoAToken proxy address accordingly. On mainnet this
will correctly predict offset 3 (HDCL not initialized until the proposal).

### 7. HDCL registered as Token instead of Erc20 (cost: lark needs remediation; mainnet code now correct)

The original proposal task copied Yash's GIGAHDX pattern verbatim:
`assetType: "Token"` with `location: null` for the underlying collateral.
That's correct for stHDX (a substrate-native asset with no EVM contract) but
wrong for HDCL — HDCL *is* an EVM contract (the vault). When registered as
`Token`, the substrate→EVM precompile at `tokenAddress(55)` does not bridge
to the actual vault contract, so `Pool.supply(HDCL, amount)` reverts on its
internal `transferFrom` call.

**Fix:** `tasks/proposals/hdcl.ts` now registers HDCL as
`assetType: "Erc20"` with `location: location(vault_proxy)`, where
`vault_proxy` is read at proposal-build time from
`HDCLOracleAdapter.vault()` (so it works on any network without
hardcoding). The aHDCL registration was always correct (`Erc20` →
HDCL aToken proxy).

The 0.lark deployment will need a remediation `assetRegistry.update(55, ...)`
to switch type/location — handled separately from this code change.

### 8. Forgot to approve Pool-Proxy-HDCL for managed-balance access (cost: every user would need a separate approve before supplying)

Hydration's EVM has a managed-contract approval mechanism: contracts in
`EVMAccounts.ApprovedContract` can call `transferFrom` on substrate-mapped
tokens without requiring an explicit `IERC20.approve` from the user. This is
how the existing money-market avoids the two-tx UX. We forgot to add the
HDCL Pool-Proxy to this list in the original proposal.

**Fix:** the proposal task now appends
`EVMAccounts.approve_contract(Pool-Proxy-HDCL)` to the substrate phase, with
an idempotency check on `EVMAccounts.ApprovedContract` storage so re-runs
don't revert.

### 9. Asset-id naming flipped after launch (no cost — caught before mainnet)

The original deploy registered the user-held aToken at asset 550 as `aHDCL`
and the underlying vault token at asset 55 as `HDCL`. After 0.lark execution
we flipped to: **asset 55 = `HDCL`** (the aToken users hold post-auto-deposit)
and **asset 550 = `DCL`** (the underlying). The flip mirrors the GDOT pattern
and reflects the actual UX flow — the UI auto-supplies the vault token (DCL)
into the Aave pool right after the user's HOLLAR→DCL deposit, so the
durable user balance is the aToken (HDCL), not the underlying.

**Fix on lark:** update both registry entries via `assetRegistry.update` on a
follow-up proposal (handled separately from this code change). **Mainnet:**
the proposal task in this branch produces the correct naming on first run —
asset 55 registers as HDCL → DCL aToken proxy, asset 550 registers as DCL →
vault proxy.

## 0.lark deployed addresses (reference)

| Component | 0.lark Address |
|---|---|
| HDCL Vault proxy | `0xB82cF8A62EB1b51a2f2A9d71C120E2fB8ae548D8` |
| HDCL Vault impl | `0x6E60c3bc3f43f71E5A5CDa929088fBa13b4102dc` |
| HDCLOracleAdapter | `0x19Cb1536947bA792d71c04F4dBa9DcDF63C840A7` |
| PoolAddressesProvider-HDCL | `0xB0fa53A6cBaF88eDD90aD27a6c396D99d272FE64` |
| Pool-Proxy-HDCL | `0x7d78C0d9c8F6635b2bc481b674bd74E2917392e8` |
| PoolConfigurator-Proxy-HDCL | `0x4e7f9e8AEaC72938254e5520B2428dD75517C6F9` |
| AaveOracle-HDCL | `0x19Cb1536947bA792d71c04F4dBa9DcDF63C840A7` (same as OracleAdapter — coincidence of deployer-nonce across two separate deploys) |
| ACLManager-HDCL | `0x68F38AeF16B6E197Bb0C86B15fDACFC461074D04` |
| AToken-HDCL (impl) | `0x75677FC81cFd0577bfd9442CCaf5D6C88e44836d` |
| AToken-HDCL (proxy for DCL reserve — bound to asset 55 `HDCL`) | `0x9cd4410c27977CD5e400e43B7B1aB5ADD845ada2` |
| GhoAToken-HDCL (impl) | `0xa67f4FB7E691414cf064aE432F3e647601e36207` |
| GhoAToken-HDCL (proxy for HOLLAR reserve) | `0x8936D09C63830062FAd22C1Eb9ED37Bc12a4659a` |
| GhoVariableDebtToken-HDCL (proxy) | `0x27633213BE89A725a25B9e4F49c5E514f6790eb3` |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` (forked from mainnet) |
| HOLLAR | `0x531a654d1696ED52e7275A8cede955E82620f99a` (mainnet constant) |
| GhoOracle (for HOLLAR) | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (mainnet constant) |
| Aave manager precompile | `0xaa7e0000000000000000000000000000000aa7e0` (Hydration constant) |

Mainnet addresses will differ for the HDCL-specific contracts; HOLLAR, GhoOracle, and the aa7e precompile are canonical and identical.

## Scripts reference

All under `scripts/`:
- `deploy-HDCLOracleAdapter.ts` (task) — Phase 2.
- `submit-hdcl-proposal.ts` — generates + submits the governance proposal. *Currently configured for lark Root-track; for mainnet, switch back to the WhitelistedCaller flow (see "Governance submission" above).*
- `transfer-hdcl-admin-to-governance.ts` — Phase 7. Idempotent.
- `grant-hdcl-risk-admin.ts` — Phase 8. Idempotent.
- `unlock-alice-votes.ts` — 0.lark-specific cleanup only. Not relevant on mainnet.

## Network config

All three hydration-family networks are configured in
`helpers/hardhat-config-helpers.ts`:

- `hydration` — mainnet (`https://rpc.hydradx.cloud`). Committable deployments at `deployments/hydration/`.
- `lark` — 0.lark (`https://0.lark.hydration.cloud`). Committable deployments at `deployments/lark/`.
- `chopsticks` — local fork (`http://localhost:8000`). Gitignored at `deployments/chopsticks/`.

Usage:
```
HARDHAT_NETWORK=<network> MARKET_NAME=HDCL npx hardhat ...
```

## Post-deploy verification (mainnet)

After mainnet governance execution, run:

```bash
# 1. Event scan — MUST show 0 failure markers
node scripts/scan-mainnet-execution.ts <fromBlock> <toBlock>  # (write if not present)

# 2. Pool state checks
cast call <Pool-Proxy-HDCL> "getReservesList()(address[])"   # [HDCL, HOLLAR]
cast call <Pool-Proxy-HDCL> "getReserveData(address)(...)" <HDCL-address>
cast call <Pool-Proxy-HDCL> "getReserveData(address)(...)" <HOLLAR-address>

# 3. Facilitator
cast call <HOLLAR> "getFacilitator(address)(uint128,uint128,string)" <predicted-GhoAToken>

# 4. Substrate state
polkadot-api:
  assetRegistry.assets(550)             # name=DCL,  type=Erc20, location=AccountKey20(vault proxy)
  assetRegistry.assets(55)              # name=HDCL, type=Erc20, location=AccountKey20(DCL aToken proxy)
  assetRegistry.assetLocations(550)     # decodes to vault proxy
  assetRegistry.assetLocations(55)      # decodes to DCL aToken proxy
  multiTransactionPayment.acceptedCurrencies(550)       # is some  (DCL)
  multiTransactionPayment.acceptedCurrencies(55)        # is some  (HDCL)
  EVMAccounts.approvedContract(<Pool-Proxy-HDCL>)       # is some

# 5. End-to-end UX check — supply with NO approve()
   In a fresh wallet that's never interacted with the pool:
   - deposit HOLLAR → vault → receive HDCL (single tx)
   - directly call pool.supply(HDCL, amount) WITHOUT first calling
     IERC20(HDCL).approve(pool, ...) — this should succeed because the pool
     is in EVMAccounts.ApprovedContract.
   - borrow HOLLAR
   - repay HOLLAR (also without explicit approve)
   - withdraw HDCL
   - redeem HDCL → HOLLAR via vault
              multiTransactionPayment.acceptedCurrencies(55) / (550)

# 6. End-to-end UI test (on mainnet vault URL)
   deposit HOLLAR → get HDCL → supply HDCL as collateral → borrow HOLLAR → repay → withdraw
```
