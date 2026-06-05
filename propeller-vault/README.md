# propeller-vault

Solidity contracts for **Propeller** — a protocol-managed leveraged-yield product on
Hydration. Deposit a volatile collateral (ETH, tBTC, DOT…), keep full 1× price
exposure, earn more of that same asset, and never be liquidated.

Full design + chain-verified spec: `garden` wiki → `note-propeller-impl`.

## Architecture (Architecture A — collateral on Aave + synthetic)

```
per collateral asset:
  CollateralVault (ERC4626, UUPS)         "deposit ETH -> pETH shares; redeem -> ETH + yield"
    ├─ supplies collateral to the Aave money market (Main position)
    ├─ borrows HOLLAR at target LTV (band-rebalanced as price moves)
    ├─ mints + supplies SyntheticToken (= HOLLAR debt) -> Main HF floored, principal un-liquidatable
    └─ routes borrowed HOLLAR ─────────────┐
                                           ▼
  SubLoop (single shared instance)   leveraged PRIME/HOLLAR loop in Aave isolation, HF ~1.05
    ├─ flash-loan-assisted open/close (atomic, one tx)
    ├─ swaps HOLLAR<->PRIME via ISwapper (Aave-aligned IParaSwapAugustus seam -> Substrate router)
    ├─ per-vault equity shares
    └─ harvest carry -> per-vault -> swap into each collateral -> compounded into the vault

  Harvester        keeper entrypoints: harvest / deLever / rebalance / maintainPeg (on-chain guarded)
  SyntheticToken   Propeller-owned ERC20; mint/burn gated to vaults; registered as an Aave reserve
```

## Status: CORE FLOWS IMPLEMENTED + TESTED (against mocks)

The full happy-path and the safety invariant are implemented and validated
test-first against Aave-faithful mocks (`MockPool` uses 8-dp USD base, bps
thresholds, WAD HF; `MockDcaScheduler` simulates the DCA tranches):

- **deposit** → Main leg (supply collateral → borrow HOLLAR → mint+supply
  synthetic → seed the loop)
- **synthetic flooring** → Main HF stays ≥ 1 at −99% ETH and at ETH≈$0 (a bare
  position is liquidated at the same price)
- **deploy ramp** → unbounded DCA + `pokeBorrow` self-ramps to HF 1.05, equity
  invariant holds, ~6.18× collateral
- **unwind** → deleveraging spiral (`executeUnwind` + `pokeRepay`) drains the
  position and frees the seed equity back, HF-safe throughout
- **full withdraw** → `requestRedeem` → unwind → `pokeSettle` (repay Main debt,
  burn synth, withdraw collateral) → `claim` returns ~the full ETH principal

- **harvest** → skim loop carry (surplus PRIME above cost basis) → compound into
  each vault's collateral → pETH share price rises; loop returns to basis
- **rebalance** → ETH appreciates → borrow more to target LTV → deploy the slack
  (yield notional tracks collateral value); INV-1 preserved
- **maintainPeg** → Main debt accrues interest → re-top synthetic so `synth·LT ≥ debt`

18 tests passing (`forge test`), incl. 6 invariants under fuzzing.

**Remaining:** `rebalance` *down*-case (de-lever on collateral drop — a loop
unwind; not safety-critical, the synthetic still floors HF); then the real
REQ-SWAP / REQ-DCA adapters, the governance proposal, and fork tests.

Design note surfaced by TDD: the synthetic is minted so **`synth·LT` slightly
exceeds debt** (≈ `debt/0.98 ×1.005`), not `synth = debt` — that's what floors
the Main HF strictly above 1 from the synthetic alone.

### External dependencies (see spec §7)
- **REQ-SWAP** — an `ISwapper` implementation backed by the Hydration Augustus
  (`IParaSwapAugustus`) routing to the Substrate router. Not yet deployed on
  mainnet; tests use a mock. This is the gating dependency for live swaps.
- Synthetic reserve registration, Propeller-scoped HOLLAR discount, PRIME
  ceiling / collateral supply-cap raises, deployer whitelist — all governance,
  shipped as an `aave-v3-deploy/tasks/proposals/propeller.ts` batch (mirrors
  `prime.ts` / `hdcl.ts`).

## Build / test

```sh
forge build
forge test            # uses MockSwapper / MockPool
forge test --fork-url $RPC_HYDRATION   # fork tests against live Aave + PRIME
```

Libs are reused from `../hdcl-vault/lib` (see `foundry.toml`).

## Future improvements (not in scope yet)

- **Flow matching / position hand-off (v2).** When a deposit and a withdrawal
  overlap, hand the exiting user's loop position directly to the entering user
  at NAV instead of delevering one and re-levering the other. Settle the
  exiter's equity from the enterer's incoming HOLLAR, transfer the loop equity
  shares, and only push the *net* imbalance through the DCA spiral. Saves both
  round-trips of swap cost and can make a matched withdrawal **instant**. In the
  share model this is just: match `min(pendingDeploy, pendingUnwind)` at
  `exchangeRate`, move shares exiter→enterer, skip both DCAs for the matched
  amount. (Generalizes the deposit↔withdrawal netting noted in the spec.)
  - **Cross-collateral matching (the nicest case).** Because the single loop is
    collateral-agnostic, an ETH-vault exit can be matched against a tBTC-vault
    entry by transferring the loop **shares** between vaults — loop position
    untouched. The enterer's freshly-borrowed HOLLAR repays the exiter's Main
    HOLLAR debt directly (HOLLAR→HOLLAR, **no swap**); each user keeps their own
    collateral asset; only the loop's funding source shifts ETH→tBTC. Saves both
    loop round-trips *and* avoids any swap entirely.
- **Bounded harvest DCA**, estimated-wait views (HDCL `getEstimatedWaitTime`
  analogue), and the optional flash fast-path for small instant exits.

## Verified mainnet anchors (2026-06-05)
| | address / id |
|---|---|
| Aave Pool | `0x1b02e051683b5cfac5929c25e84adb26ecf87b38` |
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| PRIME (EVM) | `0x000000000000000000000000000000010000002b` (asset 43, 6dp, isolation, $12M ceiling) |
| ETH (EVM) | `0x0000000000000000000000000000000100000022` (asset 34, LTV 75 / LT 85) |
