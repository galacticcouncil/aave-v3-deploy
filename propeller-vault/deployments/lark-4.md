# Propeller — Deployment on `4.lark.hydration.cloud`

**Deployed:** 2026-09-07 (supersedes 2026-08-11 and 2026-07-31 — both wiped, see [History](#history))
**Source:** `ys-propeller-fixes` @ `f70bb21`
**Network:** Hydration lark-4 (chain id `222222`, runtime **`hydradx v443`**)
**Status:** Live. `verify-readiness.ts` **79/80** (the one red row is the expected negative-carry one
— see [Verification](#verification)). **Full lifecycle proven end to end on BOTH vaults**: deposit →
ramp → redeem → keeper-settle → claim → queue drained. Both keepers running.

> **lark-4 was re-forked from mainnet between 2026-08-11 and 2026-09-07.** Every contract from
> the previous deployment is gone (`eth_getCode` returns `0x` at the old SubLoop, both vaults,
> the synth, the Harvester and HydraAugustus). The money market survived because it is part of
> the mainnet state the fork restores. Chain height was ~138k at deploy time, and substrate
> asset **5550** plus the canonical synth name were both free again — so this deployment uses
> the mainnet-canonical id and name, unlike 2026-08-11 which was forced onto `…v2`.
>
> `node4`'s fork volume key is `0x166badaca7c60814e50a4288a9c84ad4d49f2c3572ab658494c72a32aff9b30a`;
> a change to that value in the `node4` stack means another re-fork and another wipe.

---

## Addresses

| Contract | Address | Notes |
|---|---|---|
| **CollateralVault (pETH)** | `0x3645E7013C00d91D9E6c3EA3847E586967d8fc67` | UUPS proxy — canonical ETH entry point |
| **CollateralVault (ptBTC)** | `0x22fff20f7f4a7047f6975248aeafc2f013ae76cf` | UUPS proxy, shares the impl below |
| CollateralVault impl | `0xea8a66d1bb5dabced20fe9299e6444d3740b7cd7` | Behind both proxies |
| **SubLoop** | `0x1e755ba323Dbfe80CAa1bDAe37255D6f18F38CE6` | UUPS proxy — the single shared PRIME loop |
| SubLoop impl | `0x8ebe3030bb38c86de1c53a8b60538dc69ba96854` | |
| **SyntheticToken** (psHOLLAR) | `0x294862cbfaa0e4fd6d3c29e8d354b680efcafec1` | Non-upgradeable; substrate asset **5550** |
| **Harvester** | `0x5B58835f7F20FaE06e6110a75b2B558Cf37FB2A6` | Non-upgradeable |
| HydraAugustus (swapper) | `0x195c5efaa658ac3c40df6138f1c3b948ed2c83d7` | REQ-SWAP, from `../../../aave-debt-swap` |
| HydraAugustusRegistry | `0x4c9cbdf96c47e0180376bddc099b31f28261db67` | Propeller points `ISwapper` at the swapper directly; the registry is for the debt-swap adapters |

Money-market addresses are the mainnet-mirrored ones, re-verified live against
`pool.getReserveData` on 2026-09-07 — Pool `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38`,
HOLLAR `0x531a654d1696ED52e7275A8cede955E82620f99a`, vdHOLLAR `0x342923782cCaEBf9c38DD9cb40436e82C42c73B5`,
ETH `0x…0100000022` (34) / aETH `0x11a8f7fFbB7e0fbEd88BC20179Dd45B4Bd6874ff`,
PRIME `0x…010000002B` (43) / aPRIME `0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7`,
tBTC `0x…01000f453d` (1000765) / atBTC `0x69003a65189f6Ed993D3bD3E2B74f1Db39F405ce`,
governance precompile `0xAa7e0000000000000000000000000000000Aa7e0`.

Deployer `0x222222ff7Be76052e023Ec1a306fCca8F9659D80` — confirmed present in
`evmAccounts.contractDeployer` (8 entries on this fork). Whole deploy cost <0.00005 gas token.
Governance = `//Alice` (Root-track referenda; lark has no sudo).

---

## Roles

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` / `UPGRADER_ROLE` | governance precompile `0xAa7e…0aa7e0` |
| `GUARDIAN_ROLE` | governance **and** `0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b` (technical committee) |
| `VAULT_ROLE` (on SubLoop) | both CollateralVaults |
| `MINTER_ROLE` (on SyntheticToken) | both CollateralVaults |
| `KEEPER_ROLE` | **nobody** — every op the looper calls is permissionless |

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
| `compoundSlippageBps` | 100 on both vaults |
| `tvlCap` | pETH 1,000,000e18 · ptBTC 50e18 |

**Router pallet is still 67 and `router.sell` is still call index `[67, 0]` on v443** — checked with
`scripts/propeller/gen-router-reference.mjs` before deploying. `DcaDispatch` bakes those in as
compile-time constants, so this is the check that decides whether a runtime bump needs a UUPS
upgrade of SubLoop. v430, v435 and v443 are all byte-identical here; **no upgrade was needed.**

### Compound routes (BATCH 0)

`Harvester.harvest` calls `compound(prime, cut, minOut, "")` with an **empty** route, so
HydraAugustus builds `router.sell(…, [])` and the *substrate* router resolves the path from its own
storage, falling back to Omnipool when nothing is stored. **PRIME is not an Omnipool asset**, so
without stored routes every harvest reverts.

| Pair | Route | Verified after enactment |
|---|---|---|
| PRIME → ETH | `43 →[ss143]→ 222 →[omnipool]→ 420 →[aave]→ 4200 →[ss4200]→ 1007 →[aave]→ 34` | 5 hops stored |
| PRIME → tBTC | `43 →[ss143]→ 222 →[omnipool]→ 1000765` | 2 hops stored |

> **The router canonicalises asset pairs.** It stores under `(min, max)` and reverses the hops on
> the way in, un-reversing on lookup. The `43 → 34` route therefore lives under key **`34 → 43`**;
> querying `{assetIn: 43, assetOut: 34}` returns `None` even though the route is present and works.

---

## Governance batches

Emitted by `npx hardhat propeller --network hydration` (with `RPC` pointed at lark-4,
`MARKET_NAME=Hydration`; asset id and synth name left at their canonical defaults), submitted with
`scripts/propeller-submit-preimages-lark.mjs --live`.

| Batch | Referendum | Result |
|---|---|---|
| 0 — compound routes (2 calls) | #403 | ok |
| 1 — list-reserve (2 calls) | #404 | ok |
| 2 — configure (4 calls) | #405 | ok |
| 3 — wire (16 calls) | #406 | ok |

**All four enacted first time with no `ExecutedFailed` / `BatchInterrupted` events** — the first
Propeller lark deploy to do so. The 2026-08-11 run needed batches 1 and 2 re-submitted because the
name index collided with the older synth; a re-forked chain removes that class of failure entirely.

Two follow-up funding referenda (both Root, both enacted):

| Referendum | Effect |
|---|---|
| #407 | 60 ETH → `//Alice`; 100,000 HDX → `0x455448001e755ba…0000` (the SubLoop's unbound EVM account, which owns the router schedule and pays its fee) |
| #408 | 250,000 PRIME → `//Alice` (the peg keeper's stock; PRIME cannot be minted on the fly) |

---

## Verification

```sh
set -a; . .claude/tmp/lark4.env; set +a     # see "Useful one-liners"
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
  scripts/propeller/verify-readiness.ts
```

| When | Result |
|---|---|
| immediately after the wiring referenda, pre-ramp | **78/78**, exit 0 |
| after the keeper ramped the loop to target | **79/80**, exit 1 — one red row |

Sections A–I cover runtime pallet indices, substrate registration, bytecode presence, the full
synthetic reserve config, every role, every wiring value, per-vault live state, loop health and
keeper funding.

The check count rises from 78 to 80 because two loop-health rows only apply once the loop has
equity (`live HF >= targetHf`, `live HF >= 1.02`) — both pass at `hf=1.0571`.

**The single failing row is `no negative carry: negativeCarryBps=233`, and it is expected.**
Levering through a HOLLAR-heavy pool-143 buys PRIME above its oracle-fair rate, so the loop
carries a negative spread until the pool is rebalanced. It is an artefact of pool state, not a
protocol fault — the same row failed at **780 bps** on 2026-08-11. The peg keeper drives it down;
re-run the check once skew is under ~2%.

---

## E2E result (2026-09-07)

| Step | Outcome |
|---|---|
| deposit 0.5 ETH | shares `499999999999999000` (0.5 − 1000 wei DEAD_SHARES); Main HF **2.1383**; pool-143 PRIME 411,447 → 410,573 confirming the HOLLAR→PRIME sell |
| ramp (looper, automatic, 13 cycles over ~12 min) | HF ∞ → 1.926 → 1.449 → 1.291 → 1.214 → 1.168 → 1.139 → 1.118 → 1.104 → 1.093 → 1.084 → 1.078 → 1.073 → 1.068 → 1.062 → **1.0585**, settling at target 1.05 within `RAMP_HF_BUFFER` |
| leverage | 1.84× → **5.14×** |
| equity | 0 → **$900.86** |
| `negativeCarryBps` | 0 → **233** |

The ramp was driven entirely by the deployed keeper calling the permissionless `pokeBorrow()` —
no manual `propeller-ramp-lark.mjs` run was needed. `negativeCarryBps` of 233 compares with **780**
on 2026-08-11: pool-143 is ~11% skewed now versus 24.9% then, so levering through it costs far less.

The peg keeper measurably moves the pool — over its first four cycles pool-143 went
PRIME 409,844 → 422,950 and HOLLAR 639,466 → 625,652.

## Redeem lifecycle smoke test (2026-09-08)

Run from a **UI's point of view**: the script calls only `requestRedeem()` and `claim()` — the two
buttons a frontend owns — and never pokes. All settling was left to the deployed `propeller-looper`,
so this doubles as an unattended test of the keeper.

| Step | Outcome |
|---|---|
| `requestRedeem(0.1 pETH)` | request **#0**, `debtShare` 184.47, `active=true` |
| keeper settles, unattended | first `pokeRepay`+`pokeSettle` inside one 30 s cycle → 14% repaid, 0.0145 ETH claimable. **No manual pokes.** |
| `claim(#0)` × 8 rounds | +0.0145, +0.0141, +0.0136, +0.0132, +0.0128, +0.0124, +0.0121, +0.0048 ETH |
| final | request `active=false`, repaid **180.07/180.07 (100%)**, queue drained (`head == tail == 1`) |

**Result: 0.1 pETH → 0.097614 ETH returned, a 2.4% unwind cost** (2026-08-11 measured 8.7% on a
24.9%-skewed pool). `exchangeRate` **1.000002 → 1.005968** — it *rose*, so the redeemer absorbed
the unwind cost and remaining holders were not diluted. That is the intended behaviour.

`harvest` also executed successfully for the first time on any Propeller lark deployment
(`0x9e33c90a…`) — prior deploys had no compound routes, so it always reverted. BATCH 0 works.

### ptBTC — full lifecycle (2026-09-08)

The second vault was seeded and exercised the same way. tBTC (asset 1000765) is a `Token`-type
asset, so it is mintable via `currencies.updateBalance` under Root — unlike HOLLAR, which is
`Erc20`-type and reverts `currencies.NotSupported`.

| Step | Outcome |
|---|---|
| mint 0.5 tBTC to `//Alice` | referendum **#409**, enacted |
| `deposit(0.02 tBTC)` | shares **0.02** (−1000 wei DEAD_SHARES), vault `totalAssets` 0.02, Main HF **2.067** |
| shared-loop accounting | SubLoop `totalShares` 922.30 → **2060.96**, `totalEquity` $900 → **$1973.70** — one loop, two vaults |
| keeper re-ramp, unattended | HF 1.368 → 1.254 → … → **1.0598**, back at target with the combined position |
| `requestRedeem(0.004 ptBTC)` | request #0, `debtShare` 253.64 |
| keeper settle + 5 × `claim` | request closed, repaid **253.08/253.08 (100%)**, queue drained |

**Result: 0.004 ptBTC → 0.003991 tBTC, a 0.22% unwind cost**; `exchangeRate` 1.000000 → **1.000553**.
The cost is an order of magnitude below pETH's 2.4% because this position was redeemed minutes
after it was opened, so it had accrued almost no negative carry — the redeemer absorbs accrued
carry, and that dominates the unwind cost far more than pool slippage does on a balanced pool.

Both vaults sit behind the **same** `CollateralVault` implementation
(`0xea8a66d1…`), so the redeem code is byte-identical; what this proves separately is the tBTC
collateral leg — its aToken, its oracle, and the PRIME→tBTC compound route.

Note the `debtShare` printed at request time (184.47) is **larger** than the amount finally repaid
(180.07): it is a live target that shrinks as the loop's equity is unwound. A UI should show
progress as `repaid / debtShare` re-read each poll, not cache the opening value.

## For the UI

Every read below was exercised against this deployment on 2026-09-08 — **38/38 calls returned**,
none reverted.

**Reads** — `name`, `symbol`, `decimals`, `asset`, `totalAssets`, `totalSupply`, `exchangeRate`,
`convertToShares`, `convertToAssets`, `balanceOf`, `tvlCap`, `queueHead`, `queueTail`, `paused`,
`synthLtBps`, `yieldSource`, `redemptions(id)`. On the SubLoop: `healthFactor`, `totalEquity`,
`totalShares`, `negativeCarryBps`, `targetHf`, `paused`.

**Writes the UI owns** — `deposit(assets, receiver)`, `requestRedeem(shares, owner)`,
`claim(requestId, receiver)`. Everything else (`pokeBorrow`, `pokeRepay`, `pokeSettle`, `harvest`,
`rebalance`, `maintainPeg`, `deLever`) is permissionless keeper work — **the UI must never need to
call these**, and `KEEPER_ROLE` no longer exists in any of the three contracts.

**Events to index** — `Deposited(user, assets, shares)`, `RedeemRequested(requestId, owner, shares)`,
`RedeemSettled(requestId, collateral)`, `Claimed(requestId, receiver, collateral)`,
`Harvested(collateralCompounded)`, `Rebalanced(ltvBefore, ltvAfter)`, `SyntheticPegMaintained(delta)`.

**Integration gotchas:**

- **Both vault shares and both underlyings are 18 dp** (pETH/ETH, ptBTC/tBTC) — verified, no
  scaling mismatch. Do not assume tBTC is 8 dp here.
- **`redemptions(id)` has nine fields**; `sharesBurned` sits between `collateralSettled` and
  `active`. An ABI missing it decodes `sharesBurned` **as** `active` and makes a partial redemption
  look finished. This bit `propeller-redeem-lark.mjs` before it was fixed.
- **A redemption settles over several keeper cycles, not one.** `claim()` is callable repeatedly and
  pays out whatever has settled so far; the request stays `active` until `repaid == debtShare`.
  Show partial progress rather than a spinner.
- **`requestRedeem` reverts `NoLoopEquity` when the loop has not been ramped.** Deliberate — see the
  caveats. On a live vault with a running keeper this will not be hit.
- A brand-new depositor's EVM address needs `evmAccounts.bindEvmAddress()` or the dispatch
  precompile reads an empty account.
- **A freshly minted or bridged tBTC balance is partly `reserved`.** Minting 0.5 tBTC to Alice left
  `free` 0.4584 / `reserved` 0.0416 — nothing is lost (free + reserved + deposited == 0.5), but the
  ERC20 precompile's `balanceOf` reports **free only**. A UI that sizes a "max deposit" off the
  registry balance will overshoot what `approve`/`deposit` can actually move.

---

## Keepers

Both stacks run on the `lark` swarm (single node, `141.95.98.101`), managed via the `swarmpit-lark`
MCP. Both were **repointed and restarted** for this deployment — they had been running for weeks
against the wiped addresses.

### `propeller-looper`

| | |
|---|---|
| image | `iamyaxh/propeller-looper:multivault` |
| signer | `0x222222ff…` — the documented public lark test key, **not** a secret. Holds no role, only pays gas |
| cadence | `POLL_INTERVAL_MS=30000`, `SLOW_EVERY=10`, `RAMP_HF_BUFFER=0.005` |
| ops | fast: `pokeBorrow` / `deLever` / `pokeRepay`+`pokeSettle` · slow: `maintainPeg`+`rebalance` **per vault**, then one `harvest` |

> **`replicas` must stay 1** and `update_config.order` must stay `stop-first` — two loopers race on
> the signer's nonce.
>
> **The looper signs with the same key as the deploy.** Stop it before running `forge script`, or
> the two contend for `0x222222ff…`'s nonce.

### `propeller-rebalancer` (peg keeper)

| | |
|---|---|
| image | `iamyaxh/propeller-rebalancer:lark4` |
| config | `BOT_SEED=//Alice`, `THRESHOLD=0.02`, `TARGET=0.5`, `MAX_PER_CYCLE=5000`, `SLIPPAGE=0.01`, `INTERVAL=60` |

Watches pool-143's value skew and swaps back toward 1:1. Skew was **10.94%** HOLLAR-heavy at
restart; it is now selling PRIME into the pool each cycle.

> Alice is also the governance and lifecycle signer, so this bot shares her nonce. **Stop this
> stack before running any referendum or lifecycle script**, or the two will collide.
>
> After a chain re-fork this container fails every cycle with
> `Cannot read properties of undefined (reading 'call')` — a stale polkadot-js connection against
> a genesis that no longer exists. It is not a code bug; restart the service.

---

## Known caveats

- **`dcaSlippagePpm` is 8%, not 1%.** This is the slippage bound on two *permissionless*
  entrypoints (`pokeBorrow`, `pokeRepay`), so it is a real risk parameter. Pool-143 is far
  healthier than in August (11% vs 25% skew), so this is now a good candidate to tighten with
  `scripts/propeller-bump-slippage-lark.mjs` once the peg keeper has converged.
- **The loop must be ramped before anyone redeems.** PRIME is an isolation-mode reserve, so a plain
  supply never auto-enables it as collateral — only `pokeBorrow`'s explicit
  `setUserUseReserveAsCollateral` does. Until then `totalEquity()` is 0 and `requestRedeem` reverts
  `NoLoopEquity`.
- **Redemptions settle partially**, across several `pokeRepay`/`pokeSettle` rounds (~20% in one
  round). By design (`PartialClaim.t.sol`) — it is why the keeper must run continuously.
- **The `4.lark.hydration.cloud` RPC drops ~2.5% of requests** (measured 1/40, HTTP 000).
  `forge script` and ethers treat a single failed receipt poll as fatal and report a *landed*
  transaction as `Transaction dropped from the mempool` — this killed two deploy attempts, each
  time with the transaction actually mined and the nonce advanced. Front it with a retrying
  proxy (see below). Counter-intuitively the direct node route
  (`node4.lark.hydration.cloud`, tcpproxy → node) is **~10× slower** (8.4 s/req vs 0.9 s/req)
  because it bypasses subway's caching, so subway-plus-retries is the right combination.
- **lark-4 halts or stalls on its own** — see the workspace memory note. Reads keep working against
  a stopped chain, so check the block *timestamp*, not the height, before any deploy.
- lark-4 is shared with another team.
- A fresh depositor's EVM address needs `evmAccounts.bindEvmAddress()` or the dispatch precompile
  reads an empty account.
- Several lark lifecycle scripts print with **truncating BigInt division** (`x / 10n**18n`), so a
  0.5 ETH deposit renders as "depositing 0 ETH". Cosmetic; `propeller-redeem-lark.mjs` is fixed.

---

## History

| Date | Fate |
|---|---|
| 2026-09-07 | **Current.** asset 5550, canonical synth name, 78/78. |
| 2026-08-11 | Wiped by the re-fork. Had asset 5551 + `Propeller Synthetic HOLLAR v2`, 73/73. SubLoop `0x176B044f…`, pETH `0x0FFfA2B2…`, ptBTC `0xa14e6062…`, synth `0x744743c5…`, Harvester `0x2323D357…`. |
| 2026-07-31 | Wiped by the re-fork. Had asset 5550. SubLoop `0x8F790900…`, pETH `0x1D7C983B…`, ptBTC `0x294862CB…`, synth `0x6cc8cc41…`, Harvester `0x62ac93ae…`. |

Note that CREATE addresses are deterministic in `(deployer, nonce)` and the re-fork reset the
deployer's nonce, so **old addresses reappear as new, unrelated contracts** — `0x294862CB…` was the
2026-07-31 ptBTC vault and is now the synthetic token. Never assume an address identifies the same
contract across a fork.

---

## Useful one-liners

The env block used throughout this deploy lives at `.claude/tmp/lark4.env` (gitignored):

```sh
export RPC_URL=http://127.0.0.1:8545        # local retrying proxy, see caveats
export WS_URL=wss://4.lark.hydration.cloud  # proxy is HTTP-only; substrate needs the real endpoint
export POOL=0x1b02E051683b5cfaC5929C25E84adb26ECf87B38
export PROPELLER_SYNTH=0x294862cbfaa0e4fd6d3c29e8d354b680efcafec1
export PROPELLER_SYNTH_ASSET_ID=5550
export PROPELLER_SUBLOOP=0x1e755ba323Dbfe80CAa1bDAe37255D6f18F38CE6
export PROPELLER_HARVESTER=0x5B58835f7F20FaE06e6110a75b2B558Cf37FB2A6
export PROPELLER_VAULTS=0x3645E7013C00d91D9E6c3EA3847E586967d8fc67,0x22fff20f7f4a7047f6975248aeafc2f013ae76cf
export PROPELLER_SWAPPER=0x195c5efaa658ac3c40df6138f1c3b948ed2c83d7
export PROPELLER_GUARDIAN=0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b
export PROPELLER_LOOPER=0x222222ff7Be76052e023Ec1a306fCca8F9659D80
```

```sh
# health snapshot
cast call 0x1e755ba323Dbfe80CAa1bDAe37255D6f18F38CE6 'healthFactor()(uint256)' --rpc-url $RPC_URL
cast call 0x3645E7013C00d91D9E6c3EA3847E586967d8fc67 'exchangeRate()(uint256)' --rpc-url $RPC_URL

# full readiness table (exits non-zero on any red row)
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
  scripts/propeller/verify-readiness.ts

# lifecycle (env-driven; PROPOSAL_WS + SUBLOOP/VAULT)
PROPOSAL_WS=$WS_URL VAULT=$PROPELLER_SUBLOOP AMT=0.5 node scripts/propeller-deposit-lark.mjs --live
node scripts/propeller-ramp-lark.mjs --live 14      # or just let the looper do it
node scripts/propeller-redeem-lark.mjs --live 0.1   # re-run to continue an active request
```
