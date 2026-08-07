# Propeller — Deployment on `4.lark.hydration.cloud`

**Deployed:** 2026-07-31
**Network:** Hydration lark-4 (chain id `222222`, runtime `hydradx v430`)
**Status:** Live, full lifecycle proven end-to-end. **Contracts predate the current source** —
this deployment does not include the redemption fixes, the `adminUnwind` removal, the live
synth-LT read, `setSwapper`, or the Harvester registry guards. Treat it as a reference for the
*procedure*, not as a template for mainnet addresses.

---

## Addresses

| Contract | Address | Notes |
|---|---|---|
| **CollateralVault (pETH)** | `0x1D7C983Bfd8087BFB1671EF52a157cCad0ba13F8` | UUPS proxy — the canonical ETH entry point |
| **CollateralVault (ptBTC)** | `0x294862CBfaa0E4fD6d3C29E8d354B680EfCAFEc1` | UUPS proxy, shares the impl below |
| CollateralVault impl | `0x4c9cbdf96c47e0180376bddc099b31f28261db67` | Behind both proxies |
| **SubLoop** | `0x8F790900596a2172F307250389CEEF3923B56ec6` | UUPS proxy — the single shared PRIME loop |
| **SyntheticToken** (psHOLLAR) | `0x6cc8cc41ec0cfffe44d8c33d7f8af7e9757d20b3` | Non-upgradeable; substrate asset `5550` |
| **Harvester** | `0x62ac93ae66AbC9F01E58dB804Bfb417aAED9963C` | Non-upgradeable |
| HydraAugustus (swapper) | `0xbd1108369553bffbaaa1ba5c8d07a8131eb92f10` | REQ-SWAP, from `../../aave-debt-swap` |
| HydraAugustusRegistry | `0xccdab1e51c309d8921afc01c565551a90d19c9f8` | |

### Money market (mainnet-mirrored — verified live against `pool.getReserveData`)

| | Address |
|---|---|
| Aave Pool | `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38` |
| HOLLAR | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| HOLLAR variable debt | `0x342923782cCaEBf9c38DD9cb40436e82C42c73B5` |
| ETH | `0x0000000000000000000000000000000100000022` (asset 34) |
| aETH | `0x11a8f7fFbB7e0fbEd88BC20179Dd45B4Bd6874ff` |
| PRIME | `0x000000000000000000000000000000010000002B` (asset 43, 6dp, isolation) |
| aPRIME | `0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7` |
| tBTC | `0x00000000000000000000000000000001000f453d` (asset 1000765) |
| atBTC | `0x69003a65189f6Ed993D3bD3E2B74f1Db39F405ce` |
| Governance (aave-manager precompile) | `0xAa7e0000000000000000000000000000000Aa7e0` |

Deployer: `0x222222ff7Be76052e023Ec1a306fCca8F9659D80` (whitelisted `evmAccounts.ContractDeployer`).
Governance: `//Alice` (Root-track referenda — lark has no sudo pallet).

---

## Roles

All privileged roles sit on the governance precompile `0xAa7e…0aa7e0`, as granted at
`initialize`. `GUARDIAN_ROLE` was **not** delegated to a separate technical committee on
lark-4 — on mainnet it must be (batch 3 of `tasks/proposals/propeller.ts` does this).

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` / `UPGRADER_ROLE` / `GUARDIAN_ROLE` | governance precompile |
| `VAULT_ROLE` (on SubLoop) | both CollateralVaults |
| `MINTER_ROLE` (on SyntheticToken) | both CollateralVaults |

---

## On-chain config

| Field | Value |
|---|---|
| Synthetic reserve | LTV 100 bps · LT 9800 bps · bonus 10100 · borrowing disabled · $1 oracle · no supply cap |
| `targetHf` / `deployHfFloor` | 1.05 |
| `deLeverTrigger` | 1.10 |
| `deployTranche` / `unwindTranche` | 5000 HOLLAR / 5000 aPRIME |
| Route | HOLLAR `222` ↔ PRIME `43` ↔ aPRIME `1043` via stableswap pool `143` |
| `dcaSlippagePpm` | **80000 (8%)** — see caveats |
| `compoundSlippageBps` | pETH: 100 · **ptBTC: 0 (misconfigured — every compound reverts)** |
| `tvlCap` | 1,000,000e18 |

Router pallet index **67**, DCA pallet **66** — matches the constants pinned in `DcaDispatch`.
Confirmed via `scripts/propeller/gen-router-reference.mjs`.

---

## Readiness snapshot

`scripts/propeller/verify-readiness.ts`, run 2026-08-07 against the live deployment:

```
69/75 checks passed, 6 FAILED
  - harvester exposes vaultCount()          — Harvester predates the dedup/removal upgrade
  - harvester registered <pETH>             — isRegistered() not on this version
  - harvester registered <ptBTC>            — isRegistered() not on this version
  - [ptBTC] compoundSlippageBps != 0        — 0 bps: every compound into ptBTC reverts
  - [ptBTC] compoundSlippageBps <= 500      — same
  - no negative carry                       — negativeCarryBps = 605 (6.05% below cost basis)
```

The first three are expected version skew. The **ptBTC `compoundSlippageBps == 0`** is a real,
previously-unnoticed misconfiguration: the wiring referendum set it for the ETH vault only.
The negative carry is an artifact of the diagnostic churn during bring-up.

---

## E2E result (2026-07-31)

Full lifecycle proven: deposit 0.5 ETH → `pokeBorrow` ramp (HF → 1.10, equity ≈ $585) →
`requestRedeem` → `pokeRepay`/`pokeSettle` spiral → `claim` returned **+0.119 ETH**.

Two lark-4-specific fixes were required, both governance, neither a runtime upgrade — see
`../../PROPELLER-MAINNET-HANDOVER.md` for the full story and the wrong turns taken first.

---

## Known caveats

- **`dcaSlippagePpm` is 8%, not 1%.** Pool-143's HOLLAR→PRIME rate sits ~1.1% off oracle-fair,
  and the router rejected a tighter min-out. This is the slippage bound on two *permissionless*
  entrypoints, so it is a real risk parameter, not a tuning detail. Tighten it once pool depth
  improves.
- **The circuit-breaker changes (refs #371/#372) were a wrong diagnosis** and are unnecessary.
  Harmless, but revert them if tidying up.
- **The loop must be ramped before anyone redeems.** On the current source `requestRedeem`
  reverts `NoLoopEquity` in that state; on *this* deployment it silently orphaned request #0.
- lark-4 is shared with another team — changing circuit-breaker or pool config affects them.
- A fresh depositor's EVM address needs `evmAccounts.bindEvmAddress()` or the dispatch
  precompile reads an empty account.

---

## Useful one-liners

```sh
# health snapshot
cast call 0x8F790900596a2172F307250389CEEF3923B56ec6 'healthFactor()(uint256)' --rpc-url https://4.lark.hydration.cloud
cast call 0x1D7C983Bfd8087BFB1671EF52a157cCad0ba13F8 'exchangeRate()(uint256)' --rpc-url https://4.lark.hydration.cloud

# full readiness table
PROPELLER_SYNTH=0x6cc8cc41ec0cfffe44d8c33d7f8af7e9757d20b3 \
PROPELLER_SUBLOOP=0x8F790900596a2172F307250389CEEF3923B56ec6 \
PROPELLER_HARVESTER=0x62ac93ae66AbC9F01E58dB804Bfb417aAED9963C \
PROPELLER_VAULTS=0x1D7C983Bfd8087BFB1671EF52a157cCad0ba13F8,0x294862CBfaa0E4fD6d3C29E8d354B680EfCAFEc1 \
WS_URL=wss://4.lark.hydration.cloud RPC_URL=https://4.lark.hydration.cloud \
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' scripts/propeller/verify-readiness.ts

# lifecycle scripts (env-driven; set SYNTH/SUBLOOP/VAULT/HARVESTER + PROPOSAL_WS)
node scripts/propeller-deposit-lark.mjs
node scripts/propeller-ramp-lark.mjs
node scripts/propeller-redeem-lark.mjs
```
