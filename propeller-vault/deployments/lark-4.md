# Propeller — Deployment on `4.lark.hydration.cloud`

**Deployed:** 2026-08-11 (supersedes the 2026-07-31 deployment, still on-chain — see [Superseded](#superseded-deployment))
**Source:** `ys-propeller-fixes` @ `99e8163` (rebalance repayment fix, `adminUnwind` removed, live synth-LT read, `setSwapper`, Harvester registry guards)
**Network:** Hydration lark-4 (chain id `222222`, runtime `hydradx v430`)
**Status:** Live. `verify-readiness.ts` **73/73**. Full deposit → ramp → redeem → claim proven end to end.

---

## Addresses

| Contract | Address | Notes |
|---|---|---|
| **CollateralVault (pETH)** | `0x0FFfA2B2172B777788d4A5A42146E13Abc380366` | UUPS proxy — canonical ETH entry point |
| **CollateralVault (ptBTC)** | `0xa14e6062056c1fb1ebb0aacd0b18306caa9f4165` | UUPS proxy, shares the impl below |
| CollateralVault impl | `0x727a27eabb035f97e634d5c6c7f2904a5a5e8b1e` | Behind both proxies |
| **SubLoop** | `0x176B044fBD570fBA4Ad19f2061A7249732aB749f` | UUPS proxy — the single shared PRIME loop |
| SubLoop impl | `0x5be786f3ca66169f840f7cf6703f7d36a97d8e00` | |
| **SyntheticToken** (psHOLLAR) | `0x744743c5268e1d035ce6189f08ab6a6fb5644637` | Non-upgradeable; substrate asset **5551** |
| **Harvester** | `0x2323D357E708496fC43923a2D4288589f99291b8` | Non-upgradeable |
| HydraAugustus (swapper) | `0x1e755ba323dbfe80caa1bdae37255d6f18f38ce6` | REQ-SWAP, from `../../../aave-debt-swap` |
| HydraAugustusRegistry | `0x66b7a499a27c110c0ebac17e5998463fc0633e2c` | |

Money-market addresses are the mainnet-mirrored ones, re-verified live against
`pool.getReserveData` on 2026-08-11 — Pool `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38`,
HOLLAR `0x531a654d1696ED52e7275A8cede955E82620f99a`, vdHOLLAR `0x342923782cCaEBf9c38DD9cb40436e82C42c73B5`,
ETH `0x…0100000022` (34) / aETH `0x11a8f7fFbB7e0fbEd88BC20179Dd45B4Bd6874ff`,
PRIME `0x…010000002B` (43) / aPRIME `0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7`,
tBTC `0x…01000f453d` (1000765) / atBTC `0x69003a65189f6Ed993D3bD3E2B74f1Db39F405ce`,
governance precompile `0xAa7e0000000000000000000000000000000Aa7e0`.

Deployer `0x222222ff7Be76052e023Ec1a306fCca8F9659D80` (whitelisted `evmAccounts.ContractDeployer`);
whole deploy cost <0.0001 gas token. Governance = `//Alice` (Root-track referenda; lark has no sudo).

---

## Roles

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` / `UPGRADER_ROLE` | governance precompile `0xAa7e…0aa7e0` |
| `GUARDIAN_ROLE` | governance **and** `0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b` (technical committee) |
| `VAULT_ROLE` (on SubLoop) | both CollateralVaults |
| `MINTER_ROLE` (on SyntheticToken) | both CollateralVaults |
| `KEEPER_ROLE` | `//Alice`'s EVM `0xd435…8558`, granted during the E2E |

Unlike the 2026-07-31 deployment, `GUARDIAN_ROLE` **was** delegated to the technical committee here.

---

## On-chain config

| Field | Value |
|---|---|
| Synthetic reserve | LTV 100 bps · LT 9800 bps · bonus 10100 · borrowing disabled · $1 oracle · no supply cap · active |
| `targetHf` / `deployHfFloor` | 1.05 |
| `deLeverTrigger` | 1.10 |
| `deployTranche` / `unwindTranche` | 5000 HOLLAR / 5000 aPRIME |
| Route (loop) | HOLLAR `222` ↔ PRIME `43` ↔ aPRIME `1043` via stableswap pool `143` |
| `dcaSlippagePpm` | **80000 (8%)** — see caveats |
| `compoundSlippageBps` | **100 on BOTH vaults** (the old deployment left ptBTC at 0) |
| `tvlCap` | pETH 1,000,000e18 · ptBTC 50e18 |

Router pallet **67**, DCA **66** — matches the constants pinned in `DcaDispatch`, confirmed via
`gen-router-reference.mjs`. Also confirmed byte-identical on **v435** (lark-3), so a runtime bump
to v435 does not require a SubLoop upgrade.

### Compound routes (new — BATCH 0)

`Harvester.harvest` calls `compound(prime, cut, minOut, "")` with an **empty** route, so
HydraAugustus builds `router.sell(…, [])` and the *substrate* router resolves the path from its own
storage, falling back to Omnipool when nothing is stored. **PRIME is not an Omnipool asset**, so
without stored routes every harvest reverts. Neither route existed before this deployment — meaning
compound was never functional on any previous Propeller lark deploy.

| Pair | Route |
|---|---|
| PRIME → ETH | `43 →[ss143]→ 222 →[omnipool]→ 420 →[aave]→ 4200 →[ss4200]→ 1007 →[aave]→ 34` |
| PRIME → tBTC | `43 →[ss143]→ 222 →[omnipool]→ 1000765` |

> **The router canonicalises asset pairs.** It stores under `(min, max)` and reverses the hops on
> the way in, un-reversing on lookup. The `43 → 34` route therefore lives under key **`34 → 43`**;
> querying `{assetIn: 43, assetOut: 34}` returns `None` even though the route is present and works.
> All 265 stored routes on lark-4 have `assetIn < assetOut`, zero exceptions.

---

## Governance batches

Emitted by `npx hardhat propeller --network hydration` (with `RPC` pointed at lark-4,
`MARKET_NAME=Hydration`, `PROPELLER_SYNTH_ASSET_ID=5551`), submitted with
`scripts/propeller-submit-preimages-lark.mjs`.

| Batch | Referendum | Result |
|---|---|---|
| 0 — compound routes | #377 | ok |
| 1 — list-reserve | #378 → **failed**, re-run as #381 | ok |
| 2 — configure | #379 → cascade-failed, re-run as #382 | ok |
| 3 — wire | #380 | ok (16/16 calls landed) |

**Why batch 1 failed the first time:** `assetRegistry.AssetAlreadyRegistered`. The registry's
`assetIds` index is keyed on **NAME only** (symbol is not indexed), and the superseded 2026-07-31
synth still holds the name `Propeller Synthetic HOLLAR` at asset 5550 — so registering 5551 with
the same name failed the whole `batchAll`, which then cascaded into batch 2 (`configureReserveAsCollateral`
on a reserve that did not exist → 3× `evm.ExecutedFailed`). Re-run with
`PROPELLER_SYNTH_NAME="Propeller Synthetic HOLLAR v2"`. **Mainnet keeps the canonical name** — this
is purely an artefact of deploying twice onto one chain.

---

## E2E result (2026-08-11)

| Step | Outcome |
|---|---|
| deposit 0.5 ETH | shares `499999999999999000` (0.5 − 1000 wei DEAD_SHARES); Main HF 2.138; pool-143 PRIME 264,063 → 263,475 confirming the HOLLAR→PRIME sell |
| ramp (11× `pokeBorrow`) | HF 2.138 → **1.0701**, `totalEquity` 0 → **$565** |
| `requestRedeem` 0.1 pETH | request #0, `debtShare` 123.85 |
| spiral (`pokeRepay` + `pokeSettle`) | settled over 5 iterations, `repaid` reached `debtShare` |
| `claim` | **+0.0913 ETH total** returned (0.0196 + 0.0717 across two partial claims) |
| final | queue drained (`queueHead == queueTail == 1`), Alice 0.4 pETH, `exchangeRate` **1.0218e18** |

The redeemer absorbed the ~8.7% unwind cost and `exchangeRate` *rose* for remaining holders — the
intended behaviour. The cost is consistent with an 8% slippage bound against a pool-143 that is
currently **24.9% skewed** HOLLAR-heavy (PRIME 264k / HOLLAR 788k).

---

## Keeper

Swarm stack **`propeller-looper`** on the `lark` swarm (single node, `141.95.98.101`), managed via
the `swarmpit-lark` MCP. Repointed from lark-2 to lark-4 on 2026-08-11.

| | |
|---|---|
| image | `iamyaxh/propeller-looper:multivault` (`sha256:061bca79…`) |
| signer | `0x222222ff…` — the documented public lark test key (`hydration-node/launch-configs/fork/README.md:44`), **not** a secret. Every op it calls is permissionless, so it holds no role and only pays gas |
| cadence | `POLL_INTERVAL_MS=30000`, `SLOW_EVERY=10`, `RAMP_HF_BUFFER=0.005` |
| ops | fast: `pokeBorrow` / `deLever` / `pokeRepay`+`pokeSettle` · slow: `maintainPeg`+`rebalance` **per vault**, then one `harvest` |

> **`replicas` must stay 1** and `update_config.order` must stay `stop-first` — two loopers race on
> the signer's nonce.

Three bugs were fixed to make this deployment work at all; the published
`galacticcouncil/propeller-looper:latest` (2026-06-09) still has all three:

1. **The bot only ever ramped.** The stack set `VAULT_ADDRESSES` while the code read
   `VAULT_ADDRESS`, so the vault was `undefined` and `pokeSettle` / `rebalance` / `maintainPeg` /
   `harvest` were all silently skipped. Now genuinely multi-vault.
2. **One SubLoop backs several vaults**, so each vault's redeem queue needs its own `pokeSettle`.
   `pokeRepay` stays once per cycle (it is on the shared SubLoop), and `harvest` stays once per
   cycle (the Harvester walks its own registry).
3. **`setInterval` overlapped cycles.** A slow cycle submits up to 6 transactions, each awaiting a
   receipt at ~12 s/block — far longer than the 30 s interval. `setInterval` fired regardless, so
   cycles overlapped and raced on the nonce *inside a single replica*. Replaced with a
   self-scheduling loop that sleeps after each cycle.

The image lives under a personal namespace because the deploying account has no write access to the
`galacticcouncil` org — move it there and flip the `image:` line when that is sorted.

### Peg keeper

Swarm stack **`propeller-rebalancer`**, image `iamyaxh/propeller-rebalancer:lark4`
(`sha256:1a3dfe53…`). Watches pool-143's value skew and swaps back toward 1:1 — selling PRIME when
the pool is HOLLAR-heavy, HOLLAR when it is PRIME-heavy.

`BOT_SEED=//Alice`, `THRESHOLD=0.02`, `TARGET=0.5`, `MAX_PER_CYCLE=5000`, `SLIPPAGE=0.01`,
`INTERVAL=60`.

Alice was seeded with **250,000 PRIME** via Root referendum #385
(`currencies.updateBalance(alice, 43, 250000e6)`) — the PRIME direction is bounded by that
pre-fund, since PRIME cannot be minted on the fly. The HOLLAR direction is mintable via HSM.

> Alice is also the governance and lifecycle signer, so this bot shares her nonce. **Stop this
> stack before running any referendum or lifecycle script**, or the two will collide.

Skew was 24.90% at deploy. It falls slowly at first because the looper's ramp pushes HOLLAR into the
same pool; it should converge once the loop settles at target HF. `dcaSlippagePpm` can be tightened
from 8% once it does.

---

## Known caveats

- **`dcaSlippagePpm` is 8%, not 1%.** This is the slippage bound on two *permissionless*
  entrypoints (`pokeBorrow`, `pokeRepay`), so it is a real risk parameter, not a tuning detail.
  It is wide because pool-143 sits ~24.9% off balance. Tighten it once the peg keeper runs.
- **`negativeCarryBps` was 780** after ramping — an artefact of levering through the skewed pool,
  not a protocol fault. `verify-readiness`'s "no negative carry" row will fail until the pool is
  rebalanced.
- **The loop must be ramped before anyone redeems.** PRIME is an isolation-mode reserve, so a plain
  supply never auto-enables it as collateral — only `pokeBorrow`'s explicit
  `setUserUseReserveAsCollateral` does. Until then `totalEquity()` is 0 and `requestRedeem` reverts
  `NoLoopEquity`.
- **Redemptions settle partially, across several `pokeRepay`/`pokeSettle` rounds.** A single round
  settled only ~20%. This is by design (`PartialClaim.t.sol`), and is why the keeper must run
  continuously.
- **lark-4 halts on its own every day or two** — see [[lark-fork-instability]]. Reads keep working
  against a stopped chain, so check the block *timestamp*, not the height, before any deploy.
- lark-4 is shared with another team.
- A fresh depositor's EVM address needs `evmAccounts.bindEvmAddress()` or the dispatch precompile
  reads an empty account.

---

## Superseded deployment

The 2026-07-31 deployment is **still live on this chain** and still holds substrate asset **5550**
under the canonical name `Propeller Synthetic HOLLAR`. It predates every fix in `99e8163` and its
readiness run was 69/75. Do not use it; it is retained only because a fresh fork was not wanted.

SubLoop `0x8F790900596a2172F307250389CEEF3923B56ec6` · pETH `0x1D7C983Bfd8087BFB1671EF52a157cCad0ba13F8` ·
ptBTC `0x294862CBfaa0E4fD6d3C29E8d354B680EfCAFEc1` · synth `0x6cc8cc41ec0cfffe44d8c33d7f8af7e9757d20b3` ·
Harvester `0x62ac93ae66AbC9F01E58dB804Bfb417aAED9963C` · swapper `0xbd1108369553bffbaaa1ba5c8d07a8131eb92f10`.

---

## Useful one-liners

```sh
# health snapshot
cast call 0x176B044fBD570fBA4Ad19f2061A7249732aB749f 'healthFactor()(uint256)' --rpc-url https://4.lark.hydration.cloud
cast call 0x0FFfA2B2172B777788d4A5A42146E13Abc380366 'exchangeRate()(uint256)' --rpc-url https://4.lark.hydration.cloud

# full readiness table (exits non-zero on any red row)
RPC_URL=https://4.lark.hydration.cloud WS_URL=wss://4.lark.hydration.cloud \
POOL=0x1b02E051683b5cfaC5929C25E84adb26ECf87B38 \
PROPELLER_SYNTH_ASSET_ID=5551 \
PROPELLER_SYNTH=0x744743c5268e1d035ce6189f08ab6a6fb5644637 \
PROPELLER_SUBLOOP=0x176B044fBD570fBA4Ad19f2061A7249732aB749f \
PROPELLER_HARVESTER=0x2323D357E708496fC43923a2D4288589f99291b8 \
PROPELLER_VAULTS=0x0FFfA2B2172B777788d4A5A42146E13Abc380366,0xa14e6062056c1fb1ebb0aacd0b18306caa9f4165 \
PROPELLER_SWAPPER=0x1e755ba323dbfe80caa1bdae37255d6f18f38ce6 \
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' scripts/propeller/verify-readiness.ts

# lifecycle (env-driven; PROPOSAL_WS + SUBLOOP/VAULT)
node scripts/propeller-deposit-lark.mjs --live      # AMT=0.5
node scripts/propeller-ramp-lark.mjs --live 14
node scripts/propeller-redeem-lark.mjs --live 0.1   # re-run to continue an active request
```
