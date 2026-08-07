# propeller-vault

Solidity contracts for **Propeller** — a protocol-managed leveraged-yield product on
Hydration. Deposit a volatile collateral (ETH, tBTC, DOT…), keep full 1× price
exposure, earn more of that same asset, and never have the principal liquidated.

Full design + chain-verified spec: `garden` wiki → `note-propeller-impl`; machine-checked
invariants live in `formal/` (Lean 4 — see `formal/README.md`).

## Architecture (Architecture A — collateral on Aave + synthetic floor + shared PRIME loop)

```
per collateral asset:
  CollateralVault (ERC4626-ish, UUPS)      "deposit ETH -> pETH shares; redeem -> ETH + yield"
    ├─ supplies collateral to the Aave money market (Main position)
    ├─ borrows HOLLAR against it at the reserve's live max LTV (re-levered on rebalance())
    ├─ mints + supplies SyntheticToken (= HOLLAR debt · buffer) -> Main HF floored, principal
    │   un-liquidatable at ANY collateral price (see formal/ floor theorems)
    └─ routes 100% of the borrowed HOLLAR ──────────┐
                                                     ▼
  SubLoop (single instance, SHARED across every CollateralVault/collateral)
    ├─ leveraged PRIME position in Aave isolation mode, self-ramped to targetHf (~1.05)
    │   via permissionless pokeBorrow (borrow HOLLAR -> router-sell -> supply aPRIME)
    ├─ every vault owns loop *shares*, priced off the loop's live NAV (no swap seam here —
    │   HOLLAR<->aPRIME goes straight through pallet_route::sell via the 0x0401 precompile)
    ├─ async, gradual unwind: requestUnwind() records a target; pokeRepay() grinds it down
    │   tranche-by-tranche (sell aPRIME -> repay loop debt -> credit freed HOLLAR to the vault)
    └─ harvest() skims equity above cost basis (surplus PRIME) -> Harvester

  Harvester        permissionless entrypoints: harvest() (skim + pro-rata compound),
                   deLever() (trip the loop's safety de-lever when HF <= trigger)
  SyntheticToken   Propeller-owned ERC20 (18dp, $1-pegged); mint/burn gated to vaults;
                   registered as an Aave reserve with LTV 0 / LT ~98% / no borrow power
```

All keeper-style operations (`pokeBorrow`, `pokeRepay`, `pokeSettle`, `harvest`, `rebalance`,
`maintainPeg`, `deLever`) are **permissionless** — each is bounded (tranche-capped, HF-guarded,
oracle-fair minOut) so a caller can only advance protocol state, never extract value. No
`KEEPER_ROLE` exists; a bot calls them for gas-cost reasons only, not authorization.

## How a user earns yield — end to end

This is the full lifecycle for one depositor, concretely, from `deposit` to `claim`.

### 1. Deposit — open a floored, leveraged position

`CollateralVault.deposit(assets, receiver)` for, say, 1 ETH at $2,000 (Aave ETH reserve:
LTV 75% / LT 85%, per the verified mainnet anchors below):

1. **Supply**: the vault deposits your 1 ETH into the Aave money market (the vault's own
   "Main" Aave account — one shared account per `CollateralVault`, not per user). You get
   `pETH` shares minted 1:1 with `assets` pre-yield (`convertToShares`, ERC4626-style).
2. **Borrow HOLLAR**: the vault borrows HOLLAR against *only the collateral delta this
   deposit just added* (not the whole account — sizing off the total would over-borrow on
   top of an existing position, see Aave error 36 guard), at the reserve's live max LTV.
   For 1 ETH @ 75% LTV that's ~1,500 HOLLAR (bps precision, read live off
   `pool.getConfiguration`, never cached).
3. **Mint the synthetic floor**: the vault mints `SyntheticToken` sized so
   `synth · ltSynth ≥ mainDebt · 1.005` (a 0.5% buffer) and supplies it into the *same* Main
   Aave account. Because the synthetic's liquidation threshold (~98%) alone covers the HOLLAR
   debt, **the Main position's health factor is floored above 1 independent of the ETH
   price** — even at ETH → $0, this account cannot be liquidated. (Proved for all prices
   ≥ 0 in `formal/PropellerLean/Spec/Floor.lean::never_liquidated_at_any_price`.) This is
   the mechanism behind "keep full 1× ETH exposure, never liquidated" — the leverage risk is
   entirely walled off into the shared loop, not the user's Main position.
4. **Deploy into the shared loop**: the full ~1,500 HOLLAR borrowed is transferred into the
   single shared `SubLoop.deposit()`, which mints this vault loop *shares* priced at the
   loop's current NAV (first depositor gets 1 share/HOLLAR; later depositors dilute against
   accrued equity — same non-manipulable share-price pattern as the outer vault).

At this point your 1 ETH sits in Aave earning nothing extra directly — the yield engine is
entirely inside the shared loop your borrowed HOLLAR just seeded.

### 2. The shared loop — where the yield actually comes from

`SubLoop` runs **one leveraged PRIME position** shared by every `CollateralVault`, regardless
of collateral asset (ETH- and tBTC-seeded HOLLAR sit in the same loop). It is not a swap-and-
hold: it self-levers PRIME's own Aave supply APY.

- **`pokeBorrow()`** (permissionless, called repeatedly by a bot): borrows HOLLAR against the
  loop's current aPRIME collateral, capped so HF never dips below `deployHfFloor`, then
  immediately router-sells that HOLLAR → PRIME → supplies it as `aPRIME` in the same
  transaction (`pallet_route::sell`, oracle-fair min-out — not pool spot, so it resists
  manipulation). Repeated calls ramp the position up to `targetHf` (~1.05), at which point
  borrowing power is exhausted and the ramp stops on its own.
- Net effect: PRIME's base lending yield is leveraged roughly `1 / (1 - 1/targetHf)` ≈ several
  ×, funded entirely by borrowed HOLLAR that traces back to every vault's deposit — this is
  the "loop."
- **`maintainPeg()` / `rebalance()`** keep the Main-side floor and LTV correct as HOLLAR debt
  accrues interest and as ETH price moves (re-lever up when the collateral appreciates so
  yield notional tracks its value; de-lever the loop slice down when it falls).

### 3. Harvest — surplus PRIME becomes more of *your* collateral

The loop's total equity (`totalEquity()`, Aave account value) grows over time as PRIME's
supply APY accrues, pushing it above `principalEquity` (the HOLLAR cost basis every vault
seeded). Anyone can call:

- **`SubLoop.harvest()`**: computes `surplus = totalEquity - principalEquity - unwindTargetEquity`
  (in-flight redemptions are explicitly excluded — they're not carry, see
  `FUTURE_IMPROVEMENTS.md` bug G), gated by a minimum threshold so dust doesn't get skimmed,
  withdraws that surplus as **PRIME** (never touching principal — HF stays at target), and
  sends it to the registered `Harvester`.
- **`Harvester.harvest(minOuts[])`**: splits the PRIME surplus **pro-rata by each vault's loop
  shares** and calls `compound(PRIME, cut, minOut, route)` on every registered vault in turn.
  A registry-completeness check (`registeredShares == totalShares`) fails loudly rather than
  silently stranding a vault's cut.
- **`CollateralVault.compound()`**: swaps its PRIME cut into *that vault's own collateral*
  (ETH for the ETH vault, tBTC for the tBTC vault — never cross-contaminated) at an
  oracle-fair floor (`_fairCollateralOut`, AaveOracle-priced, so even a malicious caller-
  supplied route/minOut can only tighten the fill, never worsen it), then **supplies that ETH
  straight into the Main Aave position** — growing the vault's aToken balance.

Since `totalAssets() == collateralAToken.balanceOf(vault)` and `exchangeRate() =
totalAssets/totalSupply`, growing the aToken balance **without minting new shares** directly
raises the ETH-per-pETH-share price. This is the entire "deposit ETH, earn more ETH"
mechanism — depositors never receive PRIME, HOLLAR, or any token but their own collateral;
the swap happens once, inside `compound`, on their behalf.

**No user action required at either step, and compounding auto-reinvests into more yield —
not just idle balance.** `compound()` itself only supplies the swapped-in ETH — it does not
borrow more HOLLAR or grow the loop in the same call. But that extra ETH raises the vault's
collateral value, which is exactly what `rebalance()` (§ above, permissionless, called by a
bot — never the user) watches for: once compounding (or price appreciation) has widened the
gap between the vault's current LTV and the reserve's live max LTV past the 500bps band,
`rebalance()` borrows more HOLLAR against the *new, larger* collateral base, mints the
matching synthetic, and deploys that HOLLAR into the shared loop (`subLoop.deposit`) — growing
the position's loop shares, and with them its slice of every future harvest. So a deposit left
untouched compounds in two stages, both bot-driven and neither requiring the depositor to lift
a finger: **harvest → compound()** lifts the share price immediately, and the next
**rebalance()** re-levers the now-larger collateral base back into the loop, so subsequent
harvests are skimmed off a bigger position. The user never re-deposits, re-stakes, or claims
anything until they choose to redeem.

### 4. Redeem — cashing out at the appreciated share price

`requestRedeem(shares, owner)` is async (ERC-7540-style), because unwinding the shared loop
takes gradual, HF-safe tranches:

1. The vault snapshots this request's **proportional slice** of the Main position at request
   time: `collateralOwed`, `debtShare` (Main HOLLAR debt), `synthShare`, and `loopSlice`
   (shares in the shared loop) — all `shares / totalSupply` of the current totals, so
   settlement is deterministic regardless of what happens afterward.
2. The vault calls `SubLoop.requestUnwind(loopSlice)`, which converts the share slice to an
   equity target (HOLLAR) and registers it; the vault's own loop shares are burned
   immediately (they no longer earn future harvests).
3. `SubLoop.pokeRepay()` (permissionless, gradual) grinds the unwind down: each call sells an
   HF-safe sliver of aPRIME → HOLLAR via the router, repays loop debt with it, and credits
   the freed equity **pro-rata across all open unwind requests** (`_creditFreed` — weighted by
   remaining-to-credit, not raw requested, which is exactly the bug-G fix: weighting by the
   raw request number over-credits once any round free-without-pulls).
4. `CollateralVault.pokeSettle()` pulls its share of freed HOLLAR from the loop
   (`pullFreed()`), repays the corresponding slice of Main HOLLAR debt, releases + burns the
   matching synthetic, and withdraws the matching ETH from Aave — marking the request
   claimable. This can span several calls as the unwind grinds down (FIFO across the queue).
5. **`claim(requestId, receiver)`** pays out `collateralOwed` in ETH. Because compounded
   harvests raised `totalAssets()` between deposit and redemption without diluting your
   shares, `collateralOwed` for the same share count is now **more ETH than you deposited** —
   that's the realized yield, paid entirely in the asset you put in.

### Summary of the money path

```
your ETH ─► Aave Main position (supply) ─┐
                                          ├─► synthetic floor (HF ≥ 1 forever)
your ETH's borrowing power ─► HOLLAR ─────┘
                    │
                    ▼
         shared SubLoop: HOLLAR ─(router)─► PRIME ─(Aave supply)─► aPRIME, levered to HF ~1.05
                    │
       PRIME lending yield accrues, equity > cost basis
                    │
                    ▼
        harvest() skims surplus PRIME ─► Harvester splits pro-rata by loop shares
                    │
                    ▼
        compound(): PRIME ─(swap, oracle-fair floor)─► YOUR collateral ─► supplied to YOUR Main position
                    │
                    ▼
        your vault's aToken balance ↑ ⇒ exchangeRate() ↑ ⇒ your pETH is worth more ETH  (no user action)
                    │
                    ▼
        rebalance() [bot, permissionless]: LTV headroom from the bigger collateral base ⇒
        borrow more HOLLAR ⇒ mint more synthetic ⇒ deposit into the shared SubLoop  (no user action)
                    │
                    └──────────────────────► loop shares ↑ ⇒ bigger cut of every future harvest ─┐
                                                                                                   │
                    ┌──────────────────────────────────────────────────────────────────────────────┘
                    ▼
        (repeats: bigger position ⇒ bigger harvests ⇒ bigger compounds ⇒ bigger rebalances — a user
         who never touches their deposit still compounds through both stages, indefinitely)
                    │
                    ▼
        requestRedeem → (async, gradual unwind) → pokeSettle → claim: you receive > 1 ETH per ETH deposited
```

## Status: core flows implemented, tested, and formally specified

`forge test`: **72 tests across 22 suites** (71 pass, 1 skip — incl. a 6-property fuzzed
invariant suite over `Handler.sol`), all green against Aave-faithful mocks (`MockPool` models
8dp USD base + bps thresholds + WAD HF + isolation mode; `MockDispatch` etches the real
SCALE-encoded router-sell precompile so route semantics match mainnet, not a stub — and the
live `pallet_route::sell` encoding is pinned byte-for-byte against runtime metadata).

**Mainnet readiness** — see `AUDIT.md` (living finding ledger), `DEPLOYMENT.md` (runbook),
`deployments/` (address registry), `x-ray/` (pre-audit report) and
`../PROPELLER-MAINNET-HANDOVER.md` (what has already gone wrong). The two blockers are an
independent human audit and a fork-test suite; everything else is tracked in the ledger.

- **deposit** → Main leg (supply collateral → borrow HOLLAR → mint+supply synthetic → seed
  the shared loop)
- **synthetic flooring** → Main HF stays ≥ 1 at −99% ETH and at ETH≈$0 (a bare position would
  be liquidated at the same price) — machine-checked for *all* prices in `formal/`
- **deploy ramp** → `pokeBorrow` self-ramps the shared loop to `targetHf` ≈ 1.05
- **unwind** → the deleveraging spiral (`pokeRepay`) drains a requested slice and frees the
  seed equity back, HF-safe throughout, pro-rata credited across concurrent unwinders
- **full withdraw** → `requestRedeem` → unwind → `pokeSettle` (repay Main debt, burn synth,
  withdraw collateral) → `claim` returns principal + compounded yield
- **harvest** → skim loop carry above cost basis → pro-rata split → compound into each
  vault's own collateral → share price rises; loop equity returns toward basis
- **rebalance** (both directions) → ETH appreciates → borrow more to the live max LTV → deploy
  the slack; ETH falls → de-lever the loop slice that restores the real-collateral ratio
- **maintainPeg** → Main debt accrues interest → re-top synthetic so `synth·LT ≥ debt`
- **multi-vault** → the shared loop correctly isolates and conserves equity/shares across
  concurrent vaults on different collateral assets (formally proved: share conservation +
  isolation, see `formal/README.md`)
- **audit remediation (bugs A–G)** — see `FUTURE_IMPROVEMENTS.md` for the full backlog and
  what's fixed on this branch vs. still open
- **Verity EVM-bridge feasibility spike** — verdict **GO (qualified)**; a real Propeller
  contract (`SyntheticToken`) compiles through the Lean→Yul pipeline and its mint/burn specs
  are machine-checked (`formal/BRIDGE_SPIKE.md`)

### External dependencies (see spec §7)
- **REQ-SWAP** — an `ISwapper` implementation backed by the Hydration Augustus
  (`IParaSwapAugustus`) routing to the Substrate router. Not yet deployed on mainnet; tests
  use a mock. Gating dependency for `compound`'s live swaps (the loop itself no longer needs
  it — HOLLAR↔aPRIME goes straight through `pallet_route::sell`).
- Synthetic reserve registration, Propeller-scoped HOLLAR discount, PRIME ceiling /
  collateral supply-cap raises, deployer whitelist — all governance, shipped as an
  `aave-v3-deploy/tasks/proposals/propeller.ts` batch (mirrors `prime.ts` / `hdcl.ts`).

### Open — not yet shipped
- **Independent human audit** — the in-repo review is AI-assisted and says so. Launch blocker.
- **Fork tests** — zero. Aave, the AaveOracle, the 0x0401 router precompile and HydraAugustus
  are all exercised only against mocks. Launch blocker.
- **REQ-DISCOUNT (redemption discount mechanism)** — unimplemented. The real net carry from
  the loop alone is ~8.6% (`maxLtv · loopLeverage · spread`); any higher headline number
  assumes a redemption-discount mechanism that doesn't exist in the code yet.
- **PRIME mirror oracle** still owned by the looper hot key (fine for testnet; needs
  governance ownership + an updater role before mainnet).

### Deliberately not built
- **No admin emergency wind-down.** An earlier `adminUnwind()` force-unwound a live position
  out of its yield source, paused the vault, and de-risked everyone to bare collateral. It was
  removed: it locked non-redeeming holders behind a drain guard that realized slippage could
  make unsatisfiable, and that guard's tolerance scaled with position size rather than being
  true dust. To stop flow into a source now: `pause()` (guardian), then let holders redeem
  through the normal queue.
- **No in-place yield-source migration.** `setYieldSource` is a deploy-time wiring lever only —
  `DEAD_SHARES` keep `loopShares` permanently non-zero once a vault is funded, so the guard is
  unsatisfiable afterwards by construction. Changing a live vault's source means deploying a
  new vault.

Full backlog, dismissed false positives, and per-bug detail: `FUTURE_IMPROVEMENTS.md`.

## Build / test

```sh
forge build
forge test            # uses MockSwapper / MockPool / MockDispatch
forge test --fork-url $RPC_HYDRATION   # fork tests against live Aave + PRIME
```

Libs are reused from `../hdcl-vault/lib` (see `foundry.toml`).

Formal spec (Lean 4, separate Lake project, ignored by the Foundry build):
```sh
cd formal && . ~/.elan/env && lake build
```
See `formal/README.md` for the full theorem index.

## Future improvements (not in scope yet)

- **Flow matching / position hand-off (v2).** When a deposit and a withdrawal overlap, hand
  the exiting user's loop position directly to the entering user at NAV instead of delevering
  one and re-levering the other. Settle the exiter's equity from the enterer's incoming
  HOLLAR, transfer the loop equity shares, and only push the *net* imbalance through the
  unwind/deploy spiral. Saves both round-trips of swap cost and can make a matched withdrawal
  **instant**. In the share model this is just: match `min(pendingDeploy, pendingUnwind)` at
  `exchangeRate`, move shares exiter→enterer, skip both spirals for the matched amount.
  - **Cross-collateral matching (the nicest case).** Because the single loop is
    collateral-agnostic, an ETH-vault exit can be matched against a tBTC-vault entry by
    transferring the loop **shares** between vaults — loop position untouched. The enterer's
    freshly-borrowed HOLLAR repays the exiter's Main HOLLAR debt directly (HOLLAR→HOLLAR, no
    swap); each user keeps their own collateral asset; only the loop's funding source shifts
    ETH→tBTC. Saves both spiral round-trips *and* avoids any swap entirely.
- **Bounded harvest cadence**, estimated-wait views (HDCL `getEstimatedWaitTime` analogue),
  and an optional fast-path for small instant exits.

## Verified mainnet anchors (2026-06-05)
| | address / id |
|---|---|
| Aave Pool | `0x1b02e051683b5cfac5929c25e84adb26ecf87b38` |
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| PRIME (EVM) | `0x000000000000000000000000000000010000002b` (asset 43, 6dp, isolation, $12M ceiling) |
| ETH (EVM) | `0x0000000000000000000000000000000100000022` (asset 34, LTV 75 / LT 85) |
