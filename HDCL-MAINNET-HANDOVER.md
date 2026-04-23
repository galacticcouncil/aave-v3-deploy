# HDCL Mainnet Deployment Handover

This document is the authoritative runbook for launching the HDCL Aave V3
instance on Hydration mainnet. It supersedes the earlier `HDCL-DEPLOYMENT.md`
phase plan — that one had phases 3 and 4 in the wrong order and missed the
admin-transfer step, both of which bit us hard on 0.lark.

**Status at time of writing (2026-04-23):** HDCL launched successfully on
0.lark after multiple recovery runs. Ref 324 on 0.lark was the clean
execution. All addresses + artifacts captured in `deployments/lark/`.

## Components

- **HDCL Vault** — `aave-v3-deploy/hdcl-vault/` (Foundry). Users deposit
  HOLLAR, get HDCL vault shares, vault deploys HOLLAR into Decentral.
- **HDCLOracleAdapter** — `aave-v3-deploy/contracts/HDCLOracleAdapter.sol`.
  Chainlink-compat (IEACAggregatorProxy) wrapper reading `vault.exchangeRate()`,
  scaled 18→8 decimals. Consumed by Aave's AaveOracle.
- **HDCL Aave pool** — separate Aave V3 instance. ProviderId `22222255`. HDCL
  supply-only collateral, HOLLAR borrow-only (via GhoAToken facilitator).
- **HOLLAR GHO impls** — per-pool HDCL-specific versions of `GhoAToken-HDCL`,
  `GhoStableDebtToken-HDCL`, `GhoVariableDebtToken-HDCL`,
  `GhoInterestRateStrategy-HDCL` (fixed 10% APR). Built in the `hollar` repo.
- **Governance proposal** — single `batchAll` containing init-reserve + config
  calls (EVM, via `dispatcher.dispatchAsAaveManager`) plus substrate
  `assetRegistry.register` / `multiTransactionPayment.addCurrency` calls.

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
| AToken-HDCL (proxy for HDCL reserve) | `0x9cd4410c27977CD5e400e43B7B1aB5ADD845ada2` |
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
polkadot-api: assetRegistry.assets(55) / assets(550)
              multiTransactionPayment.acceptedCurrencies(55) / (550)

# 5. End-to-end UI test (on mainnet vault URL)
   deposit HOLLAR → get HDCL → supply HDCL as collateral → borrow HOLLAR → repay → withdraw
```
