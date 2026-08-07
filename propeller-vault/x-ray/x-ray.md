# X-Ray Report

> Propeller | 1,087 nSLOC | `0e7f9a4` + uncommitted (`ys-propeller-fixes`) | Foundry | 07/08/26

Analyzed branch: `ys-propeller-fixes` at `0e7f9a4`, **plus uncommitted working-tree changes**
(three redemption fixes, the `adminUnwind` removal, and a new regression suite — see
[Changes since the previous x-ray](#changes-since-the-previous-x-ray)). Git signals below
reflect only commits reachable from HEAD and therefore predate those changes.

---

## 1. Protocol Overview

**What it does:** Deposit a volatile collateral (ETH, tBTC), keep full 1× price exposure, earn more of that same asset, and never have the principal liquidated — because a Propeller-minted synthetic supplied alongside it floors the Aave health factor independent of collateral price.

- **Users**: deposit collateral into a per-asset `CollateralVault`, receive `pETH`/`ptBTC` shares, redeem asynchronously.
- **Core flow**: supply collateral to Aave → borrow HOLLAR at the reserve's live max LTV → mint + supply a $1 synthetic sized so `synth·LT > debt` → route 100% of the borrowed HOLLAR into one shared leveraged PRIME loop.
- **Key mechanism**: leverage risk is walled off into a *shared* `SubLoop` (Aave isolation mode, self-ramped to HF ≈ 1.05 via permissionless `pokeBorrow`); the user's own Main position carries zero liquidation risk by construction.
- **Token model**: `pXXX` vault shares (non-rebasing, ERC20 but **not** ERC4626-conformant); `psHOLLAR` synthetic (18dp, $1-pegged, LTV 100 bps / LT 9800, borrowing disabled); internal `SubLoop` shares (not a token).
- **Admin model**: `ADMIN_ROLE`, `UPGRADER_ROLE`, `GUARDIAN_ROLE`, `DEFAULT_ADMIN_ROLE` all granted to a single `_admin` at `initialize` — the Hydration governance aave-manager precompile `0xAa7e…0aa7e0` in every deploy script. No on-chain timelock on any of them. **No admin function moves user funds or force-unwinds a live position.**

For a visual overview, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault | `CollateralVault.sol` | 445 | Per-collateral UUPS vault: deposit, Main-position leg, async redemption queue, compound, rebalance, peg maintenance |
| Yield source | `SubLoop.sol` | 410 | Single shared leveraged PRIME/HOLLAR loop; share accounting per vault, deploy ramp, unwind spiral, de-lever, carry skim |
| Distribution | `Harvester.sol` | 78 | Skims loop carry and splits it pro-rata by loop shares into each vault's `compound()` |
| Floor primitive | `SyntheticToken.sol` | 22 | `psHOLLAR` — MINTER-gated ERC20 supplied to Aave purely to lift the Main HF |
| Runtime bridge | `lib/DcaDispatch.sol` | 132 | Hand-rolled SCALE encoder dispatching `pallet_route::sell` (and an unused `pallet_dca::schedule`) via the 0x0401 precompile |

### Backwards-Compatibility Code

- `DcaDispatch.scheduleSell` / `DcaDispatch.encodeScheduleSell` — the pallet-DCA scheduling path, superseded by `routerSell` in `c0f9404` ("drop DCA for router.sell"). No call site remains in `src/`; the only consumer is `test/DcaDispatch.t.sol`. Retained (with its pinned `DCA_PALLET = 66` / `SCHEDULE_CALL = 0` constants) but not live functionality.

### How It Fits Together

**The core trick:** the synthetic's own liquidation threshold covers the HOLLAR debt, so the Main position's health factor is floored above 1 at *any* collateral price — which means all the leverage risk can be moved into one shared loop that nobody's principal depends on.

#### Deposit — open a floored, leveraged position

```
Depositor.deposit(assets, receiver)
  ├─ _previewShares(assets, totalAssets)          — priced off PRE-deposit totalAssets
  ├─ _mint(0xdead, 1000) if first depositor       — DEAD_SHARES
  ├─ _mint(receiver, shares)
  ├─ AavePool.supply(collateral, assets)          — Main position
  ├─ borrowHollar = (collAfter8 − collBefore8) · maxLtvBps / 1e4 · 1e10
  │                                                  ↑ sized off the collateral DELTA only
  ├─ AavePool.borrow(hollar, borrowHollar, VARIABLE)
  ├─ _supplySynth(borrowHollar/synthLt · 1.005)
  │    └─ SyntheticToken.mint → AavePool.supply → try setUserUseReserveAsCollateral catch {}
  │                                                  ↑ FAIL-OPEN: floor is inert if this reverts
  ├─ SubLoop.deposit(borrowHollar)                — mints loop shares at live NAV
  │    └─ DcaDispatch.routerSell(HOLLAR → aPRIME)  — oracle-fair minOut, 0x0401 dispatch
  └─ require(syntheticSupplied · synthLtBps() / 1e4 ≥ mainDebt)  — INV-1. synthLtBps() reads
                                                     bits 16-31 of the synth reserve config LIVE
```

#### Loop ramp — where the yield comes from

```
Anyone.pokeBorrow()
  ├─ AavePool.setUserUseReserveAsCollateral(prime, true)  — aPRIME arrives without the flag
  │                                                          (PRIME is an isolation reserve)
  ├─ maxDebt8 = collBase8 · wAvgLt / deployHfFloor
  ├─ borrowHollar = min(maxDebt8 − debtBase8, deployTranche)
  ├─ AavePool.borrow(hollar, borrowHollar)
  └─ _fundDeploy → AaveOracle ×2 → routerSell(HOLLAR → PRIME → aPRIME)
                                                     ↑ repeated calls ramp to targetHf, then no-op
```

#### Harvest → compound — carry becomes more of the user's own collateral

```
Anyone.Harvester.harvest(minOuts[])
  ├─ SubLoop.harvest()
  │    ├─ surplus18 = totalEquity·1e10 − (principalEquity + unwindTargetEquity)
  │    │                                    ↑ in-flight exits excluded — they are not carry
  │    ├─ require(harvester != 0)      ↑ else HarvesterUnset — never pays the caller
  │    └─ AavePool.withdraw(prime) → transfer(harvester)
  ├─ for each registered vault: cut = surplus · sharesOf(v) / totalShares
  │    └─ CollateralVault.compound(PRIME, cut, minOut, route)
  │         ├─ floor = _fairCollateralOut(...) · (1e4 − compoundSlippageBps) / 1e4
  │         │              ↑ compoundSlippageBps == 0 ⇒ floor == exact oracle price ⇒ always reverts
  │         ├─ ISwapper.sell(PRIME → collateral)
  │         └─ AavePool.supply(collateral)   — aToken grows, no shares minted ⇒ exchangeRate ↑
  └─ require(registeredShares == totalShares)   — runs AFTER every compound
```

#### Async redeem — snapshot, grind, retire, claim

```
Holder.requestRedeem(shares, owner)
  ├─ require(yieldSource.equityOf(vault) > 0)     — else NoLoopEquity: a zero-equity source
  │                                                  would record a zero target and orphan it
  ├─ snapshot collateralOwed / debtShare / synthShare / loopSlice  = shares/totalSupply of each
  ├─ _transfer(owner → vault)                     — escrow, NOT burned
  └─ SubLoop.requestUnwind(loopSlice)

Anyone.SubLoop.pokeRepay()                         — the deleveraging spiral, repeat
  ├─ sell an HF-safe aPRIME sliver (STEP_HF_FLOOR 1.02) → HOLLAR
  ├─ repay deleverDebtTarget first (full proceeds, no split)
  ├─ repay = avail · debt / (coll + avail)         — proportional, HF preserved
  ├─ _creditFreed(remainder)                       — pro-rata by REMAINING-to-credit
  └─ _closeOutUnrealizableUnwinds()                — on a proven-permanent stall or full drain

Anyone.CollateralVault.pokeSettle()
  ├─ availableHollar += SubLoop.pullFreed()
  ├─ de-lever slice FIRST: r = min(availableHollar, deleverTarget, debtNow)
  ├─ FIFO queue: repay debtShare → burn synthShare → withdraw collateralOwed (proportional)
  └─ _retireExhaustedHead()                        — source owes nothing ⇒ snap debtShare down
                                                      to repaid so the head can advance

Owner.claim(requestId, receiver)                   — burns escrowed shares against the snapshot
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator** with **Lending/Borrowing** and **Derivatives** characteristics

ERC4626-shaped share accounting (`totalAssets`/`convertToShares`/`exchangeRate`), a strategy seam (`IYieldSource`), and `harvest()`/`compound()` give the primary type. The vault itself borrows against collateral, tracks health factors, reads LTV/LT bitmaps and repays debt — full lending semantics. The shared loop runs a levered position with a target HF and a de-lever spiral, which is derivative-like margin management, so liquidation-cascade threats apply to `SubLoop` even though no user opens a position directly.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Depositor | Untrusted | `deposit`, `requestRedeem`, `claim` (own requests only), ERC20 transfer of shares |
| Keeper / looper bot | Untrusted — holds **no** role | `pokeBorrow`, `pokeRepay`, `pokeSettle`, `rebalance`, `maintainPeg`, `compound`, `harvest`, `deLever`. All permissionless by design; the bot exists only to pay gas |
| `VAULT_ROLE` (CollateralVault) | Trusted — granted by governance via `SubLoop.registerVault` | `SubLoop.deposit` / `requestUnwind` / `pullFreed`. No revoke helper exists; removal requires raw `revokeRole` |
| `MINTER_ROLE` (CollateralVault) | Trusted | Unbounded `SyntheticToken.mint`/`burn`. The only thing keeping an LT-98 asset out of open hands |
| `ADMIN_ROLE` | Trusted, **instant** | `setTvlCap`, `setYieldSource` (deploy-time only), `setCompoundSlippageBps`, `registerVault`, `setTranches`, `configureDca`, `setParams`, `setHarvester`, `Harvester.addVault`. No timelock, no per-action bounds checks. **Cannot move funds or unwind a live position.** |
| `GUARDIAN_ROLE` | Trusted, **instant** | `pause`/`unpause` on both proxies, `pauseDeposits`/`unpauseDeposits`. Granted to `_admin` at `initialize`; intended to be delegated to the technical committee |
| `UPGRADER_ROLE` | Trusted, **instant** | UUPS replacement of `CollateralVault` and `SubLoop`. Highest privilege — full storage and logic control |

All five privileged roles are granted to the same address (`_admin` = the governance precompile) at `initialize`. There is no separation until governance explicitly re-grants.

**Adversary Ranking:**

1. **Compromised upgrader/admin** — one address holds every role on both proxies with no timelock; a UUPS replacement is unrestricted.
2. **Oracle/router manipulator** — every swap min-out derives from `AaveOracle.getAssetPrice`, consumed with no zero or freshness check, and executes through a Substrate router with a governance-set slippage tolerance currently at 8%.
3. **Market-stress cascade** — the de-lever and unwind paths only work while the loop has HF headroom and the router has depth; both assumptions weaken exactly when they are needed.
4. **Redemption griefer** — the async queue's known jam paths are now closed, but settlement remains multi-party (loop spiral → vault queue) and permissionless at every step.
5. **Donation/first-depositor attacker** — `totalAssets()` reads live token balances, so the share price is externally movable; `DEAD_SHARES = 1000` is the only structural defence.

See [entry-points.md](entry-points.md) for the full entry point map.

### Trust Boundaries

1. **Vault ↔ SubLoop** — the vault holds *shares*, not assets. It cannot enumerate or force the loop's position; it can only request and pull. Settlement therefore depends on the loop's spiral making progress, and on both sides agreeing when it has stopped. *Git signal: `SubLoop.sol` 13 modifications, 4 fix-scored commits — elevated risk.*
2. **Vault ↔ Aave** — every solvency claim the vault makes is mediated by `getUserAccountData` and `getConfiguration`. The `maxLtv` read is live; the *synthetic's* liquidation threshold is a stored copy taken at `initialize`. Governance can move the real one without the vault noticing.
3. **Admin boundary** — instant and unbounded in *configuration*, but with no fund-moving or position-unwinding power. `setParams` accepts any HF values including `targetHf < 1`; `configureDca` accepts any slippage up to 100%; `setTranches(0, 0)` disables both tranche caps.
4. **Guardian boundary** — pause/unpause only. `_pause()` freezes `deposit`, `requestRedeem`, `rebalance` and `compound` with no bare-collateral exit, so holders who have not pre-queued a redemption cannot leave while paused. `pokeSettle`/`claim` stay live so in-flight settlement completes.
5. **Upgrader boundary** — full power. `CollateralVault.__gap` is `uint256[39]`, `SubLoop.__gap` is `uint256[40]`. These are hand-maintained and unverified by any test.
6. **Runtime boundary** — `DcaDispatch` pins `ROUTER_PALLET = 67` as a compile-time constant baked into `SubLoop`'s bytecode. A Hydration runtime that renumbers pallets breaks every deploy and unwind, and the fix requires a UUPS upgrade.

### Key Attack Surfaces

- **INV-1's floor still depends on a fail-open Aave call** — `synthLtBps()` now reads the reserve's liquidation threshold LIVE (bits 16-31), so the stale-copy drift is gone. What remains: `_supplySynth`'s `try … catch {}` on `setUserUseReserveAsCollateral` means the synth can sit outside `totalCollateralBase` entirely while the storage-side guard still passes. The guard proves the vault *minted* enough synthetic, not that Aave *counts* it.
- **Wiring is fail-closed but unenforced in ordering** — `harvest()` reverts `HarvesterUnset`, `compound()` reverts while `compoundSlippageBps` is 0, and `deposit()` reverts `SynthReserveNotListed` until the reserve is listed. Nothing sequences those three, so a partially-enacted wiring batch leaves a live, permissionlessly-callable, inert deployment. `verify-readiness.ts` is the only gate.
- **The de-lever spiral is inoperable exactly when it is needed** — `pokeRepay`'s sell gate is `coll8 > minColl8` where `minColl8` holds HF at `STEP_HF_FLOOR = 1.02`. Once the loop's HF drops below that the gate never opens, so `deLever()` can set a target that `pokeRepay` can never drain, and an in-flight redemption frees nothing. Demonstrated in `AdminSourceControl.t.sol::test_adminUnwindNotBlockedByUnderSettledQueue` (PRIME −50% ⇒ `repaid == 0`). Arguably the designed risk split — the loop is the sink and Aave liquidation is the backstop — but it is undocumented as such. `SubLoop.sol:356-384`.
- **Unvalidated oracle reads** — `SubLoop._oracleRate` and `CollateralVault._fairCollateralOut` consume `getAssetPrice` with no zero or staleness assertion. A zero numerator silently collapses `minOut` to 0 while a zero denominator fail-closes. `SubLoop.sol:327-331`, `CollateralVault.sol:560-567`.
- **Shared-loop blast radius** — one `SubLoop` instance backs every collateral. A pause, stall, or router failure there halts yield and redemptions for all vaults simultaneously, and `Harvester.harvest()` reverts wholesale if any single share-holding vault is paused (`compound` is `whenNotPaused`).
- **`totalAssets()` reads live balances** — `collateralAToken.balanceOf + collateral.balanceOf` at `CollateralVault.sol:219`. The raw-balance term is required for settle→claim rate stability, but it also makes the share price movable by direct transfer, with only `DEAD_SHARES = 1000` (industry norm 1e6) resisting it.
- **Snapshot-vs-realized settlement is now resolved by write-down** — `_retireExhaustedHead` snaps a head request's `debtShare` down to `repaid` once the source is exhausted. This is what keeps the queue alive, but it means a redeemer can exit marginally short of their snapshot (measured 1.3e-11 relative at zero slippage; real slippage widens it). The write-down is unbounded in size — it is gated on source exhaustion, not on the shortfall being small. `CollateralVault.sol:455-487`.

### Upgrade Architecture Concerns

- **Storage-gap arithmetic is unverified** — `CollateralVault.__gap` is `uint256[39]` and `SubLoop.__gap` is `uint256[40]`, both maintained by hand (the vault's was just adjusted 38 → 39 when `migrationDrainRef` was deleted). No `forge inspect storage` diff or OZ upgrade-validation step exists in CI or the deploy scripts.
- **No reinitializer for appended slots** — `totalQueuedDebt` is an appended slot with no migration. Upgrading a live proxy while the redemption queue holds active requests leaves it at 0 while the queue is non-empty, mis-sizing the `rebalance` de-lever cap that now depends on it.
- **Deleting storage shifts layout** — removing `migrationDrainRef` moved `totalQueuedDebt` up one slot. Safe for a fresh deploy (which this is, per `FUTURE_IMPROVEMENTS.md`), fatal for an upgrade over the live lark-2/lark-4 proxies. Nothing in the repo enforces the distinction.
- **Two independently upgradeable contracts share invariants** — `CollateralVault.loopShares` and `SubLoop._sharesOf[vault]` must agree. Upgrading one without the other can desync them with no on-chain reconciliation.
- **`Harvester` and `SyntheticToken` are not upgradeable** — any defect is fixed only by redeploy plus a governance rewire, and `SyntheticToken` has no pause.

### Protocol-Type Concerns

**As a Yield Aggregator:**
- Share-price rounding direction is never asserted: `_previewShares`, `convertToAssets`, and `claim`'s `burnNow` all floor, but no test or comment states the round-trip direction.
- Empty-vault re-entry: `_previewShares` takes the `supply == 0` branch whenever `totalSupply()` is 0, including *after* a full exit that left residual `totalAssets`. The next depositor is priced 1:1 and captures the residual.

**As a Lending/Borrowing protocol:**
- The Main borrow is sized at exactly `maxLtv` of the collateral delta with no `availableBorrowsBase` haircut (`CollateralVault.sol:282`), so accrued HOLLAR interest can tip a later deposit into Aave error 36.
- `_maxLtvBps()` reads bits 0-15 live but nothing reads bits 16-31 (the collateral's own liquidation threshold), so the vault has no view of how close the Main position is to Aave's liquidation boundary — it relies entirely on the synthetic floor holding.

**As a Derivatives-style levered position:**
- `deLever()` sets `deleverDebtTarget` monotonically (`if (x18 <= deleverDebtTarget) revert`) with no path to cancel if HF recovers on its own, so `pokeRepay` keeps de-levering a position that is no longer unhealthy.
- `pokeBorrow` has no unwind/de-lever inhibit while `unwindTargetEquity > 0`, so a re-lever can round-trip the same sliver against an in-flight unwind at ~2× `dcaSlippagePpm`.

### Temporal Risk Profile

**Deployment & Initialization:**
- `SubLoop.initialize` sets no route ids, no tranches and no harvester; `CollateralVault.initialize` leaves `compoundSlippageBps` at 0. The contracts are live and permissionlessly callable in that state — `harvest()` pays its caller and `compound()` reverts — until the wiring referendum lands. Unmitigated; ordering is enforced only by operator discipline.
- `SubLoop.initialize` performs **no** zero-address checks on `_pool`, `_hollar`, `_prime`, `_primeAToken`, `_admin` (contrast `CollateralVault.initialize:164`, which checks three of thirteen).
- `setYieldSource` is satisfiable only before the first deposit — after that, `DEAD_SHARES` keep `loopShares` permanently non-zero. A mis-wired source must be caught in this window or the vault must be redeployed.
- The governance wiring path is currently split: the mainnet-shaped builder `tasks/proposals/propeller.ts` encodes a 6-argument `configureDca` against a contract that takes 5, grants a `KEEPER_ROLE` that no longer exists, uses lark-2 HDCL route ids, and omits `setHarvester`, `setCompoundSlippageBps` and the `GUARDIAN_ROLE` delegation. Only the lark script `scripts/propeller-wire-lark.mjs` is current.

**Market Stress:**
- Both de-lever paths depend on selling aPRIME through pool-143 at a `dcaSlippagePpm` currently configured to 8% (raised from 1% on lark-4 because the pool sits ~1.1% off oracle-fair). Thin depth is precisely the condition that triggers a de-lever, and the min-out that protects the sell is the same knob that has to be widened to let it execute.
- Below HF 1.02 the spiral stops entirely (see Key Attack Surfaces), so a sharp PRIME drawdown freezes both de-levering and redemption funding until price recovers or Aave liquidates the loop.

### Composability & Dependency Risks

> **Aave v3 Pool** (`0x1b02E051683b5cfaC5929C25E84adb26ECf87B38`) — via `CollateralVault` and `SubLoop`, ~15 call sites
> - Assumes: `getUserAccountData` returns USD 8dp; `getConfiguration` bits 0-15 are max LTV; `supply` auto-enables collateral only on first supply, with LTV > 0, and never for an isolation-mode reserve
> - Validates: HF floors computed from returned values; `setUserUseReserveAsCollateral` wrapped in try/catch on the synth path only
> - Mutability: upgradeable, governed by the same Hydration governance that owns Propeller
> - On failure: reverts propagate (fail-closed) except the synth collateral-flag enable, which fails open

> **AaveOracle** — via `SubLoop._oracleRate`, `CollateralVault._fairCollateralOut`
> - Assumes: non-zero USD 8dp price for HOLLAR, PRIME and each collateral
> - Validates: **NONE** — no zero check, no staleness check, no deviation bound
> - Mutability: source per asset is settable by governance via `setAssetSources`
> - On failure: `pPrime == 0` reverts on division; `pHollar == 0` silently sets `minOut = 0`

> **`pallet_route::sell` via dispatch precompile 0x0401** — via `DcaDispatch.routerSell`
> - Assumes: Router is pallet index 67, `sell` is call 0, and the SCALE layout matches the pinned encoding
> - Validates: only the boolean dispatch result (`DispatchFailed`); the *unused* `scheduleSell` path is the one with a byte-parity reference test
> - Mutability: changes with every Hydration runtime upgrade, outside Propeller's control
> - On failure: reverts (fail-closed), but recovery from a pallet renumber needs a contract upgrade

> **HydraAugustus / `ISwapper`** — via `CollateralVault.compound`
> - Assumes: `sell` returns at least `minOut`; the address is a real swapper
> - Validates: `out < floor` re-checked after the call (defence-in-depth vs a lying swapper)
> - Mutability: **not deployed on Hydration mainnet**; defaults to the governance precompile placeholder and cannot be repointed without a UUPS upgrade
> - On failure: reverts, blocking all compounding

> **PRIME reserve (Aave isolation mode, $12M ceiling)** — the loop's sole yield asset
> - Assumes: PRIME supply APY exceeds the HOLLAR borrow cost, and PRIME can be levered inside isolation-mode caps
> - Validates: `negativeCarryBps()` reports the shortfall as a pure view — nothing acts on it
> - Mutability: ceiling, caps and rates are all governance parameters
> - On failure: sustained negative carry means redemptions settle short and are written down by `_retireExhaustedHead`

**Token Assumptions** *(unvalidated)*:
- Collateral: assumes exact-amount transfer — `deposit` sizes shares off `assets` and borrows off the Aave collateral delta, so a fee-on-transfer collateral would over-mint shares relative to what Aave received. No balance-delta check on the collateral pull (`CollateralVault.sol:270`).
- `aPRIME`: assumed exactly 1:1 with PRIME and 6dp throughout (`_fundDeploy`, `pokeRepay`, `harvest` all hardcode `1e12` and `1e6` conversions).
- HOLLAR: assumed exactly $1 in every `· 1e10` base-to-token conversion, while `_oracleRate` simultaneously reads its real oracle price — the two assumptions coexist and diverge if HOLLAR depegs.

**Shared State Exposure**:
- Pool-143 (HOLLAR↔PRIME stableswap) is both the loop's only execution venue and the thing the loop's own flow pushes off-peg. `scripts/propeller-rebalancer.mjs` exists as an off-chain counter-pressure bot; it is unaudited and holds a pre-funded PRIME stock.
- The synthetic is registered as a real Aave reserve with LT 9800 and **no supply cap**. Only `MINTER_ROLE` custody keeps an unbounded, near-perfect collateral asset out of circulation.

---

## 3. Invariants

### Stated Invariants

- **INV-1, principal floored** — `if (syntheticSupplied * synthLtBps / BPS < hollarDebtToken.balanceOf(address(this))) revert PrincipalNotFloored()` (`CollateralVault.sol:299-303`).
- **Redemption returns at least principal** — `error PrincipalShortfall(); // withdraw invariant: collateral out >= collateral in` (`CollateralVault.sol:137`); enforced in `compound` at `:550`.
- **Carry never routes to the caller** — `IYieldSource.harvest` natspec. Contradicted by `SubLoop.sol:547` when `harvester == address(0)`.
- **`_creditFreed` never over-credits** — `SubLoop.sol:484-491`; machine-checked as `floored_credit_no_over_credit` in `formal/PropellerLean/Spec/RedeemCredit.lean`.
- **Six fuzzed invariants** (`test/invariant/PropellerInvariant.t.sol`, 256 runs × 50 calls): `invariant_escrow`, `invariant_freedBacked`, `invariant_noSynthBorrow`, `invariant_principalFloored`, `invariant_shareConservation`, `invariant_synthConserved`.
- **Machine-checked in Lean 4** (`formal/`, 0 `sorry`): `never_liquidated_at_any_price`, `floor_main_hf`, `tick_safe`, `collateral_out_ge_in`, `agg_synthConserved`, `deposit_conserved`/`deposit_isolation`, `requestUnwind_conserved`/`requestUnwind_isolation`, `principalFloored_refines`, plus `buggy_over_credits` as a negative result for bug G.

### Inferred Invariants

- **De-lever never exceeds non-queued debt**: `deleverTarget ≤ liveDebt − totalQueuedDebt`. Now enforced at `CollateralVault.sol:625-640`. If violated: `pokeSettle` repays a queued redeemer's own slice ahead of them, `repaid` never reaches `debtShare`, and the synthetic burn over-runs each request's pre-burn `synthShare` snapshot until `syntheticSupplied -= synthRel` underflows.
- **De-lever is fundable**: `deleverTarget ≤ the equity the unwound slices can free`. Now enforced at `CollateralVault.sol:642-644`.
- **A live redemption always has a non-zero unwind target**: enforced by the `NoLoopEquity` guard at `CollateralVault.sol:319`.
- **Synthetic conservation across the queue**: `Σ (synthShare − released) over active requests ≤ syntheticSupplied`. Implied by the de-lever cap; still not asserted directly on-chain, and `syntheticSupplied -= synthRel` at `:466` has no explicit floor.
- **`loopShares` mirrors `SubLoop._sharesOf[vault]`**: maintained by paired updates in `deposit`/`requestRedeem`/`rebalance`. Never asserted on-chain. If violated: `equityOf` and the de-lever slice sizing both mis-price.
- **Stored `synthLtBps` equals the synth reserve's live liquidation threshold**: assumed by INV-1 and every `synthAmt` computation. Nothing reads bits 16-31 of `getConfiguration(synthetic)` to check, and there is no setter. If violated: the floor is over- or under-provisioned while the on-chain guard still passes.
- **`totalQueuedDebt == Σ (debtShare − repaid) over active requests`**: maintained by `requestRedeem`, `pokeSettle`, and `_retireExhaustedHead`. Not seeded on upgrade.
- **Raw `collateral.balanceOf(vault)` equals unclaimed `collateralSettled`**: asserted only in a comment at `:212-218`. If violated (by donation), `exchangeRate` moves without any yield.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` (288 lines) — full money-path walkthrough, verified mainnet anchors, explicit "Open — not yet shipped" section. **Stale**: still describes `adminUnwind` semantics indirectly via `FUTURE_IMPROVEMENTS.md`'s wind-down entries |
| NatSpec | ~361 annotations | 159 in `CollateralVault`, 116 in `SubLoop`, 41 in `DcaDispatch`, 26 in `Harvester`, 19 in `SyntheticToken`. Every non-trivial branch carries a rationale comment, including rejected alternatives |
| Spec/Whitepaper | Partial | No in-repo spec; the design lives in the external `garden` wiki (`note-propeller-impl`). `formal/README.md` is the closest in-repo substitute and indexes every proved theorem |
| Inline Comments | Thorough | Comments explain *why*. `FUTURE_IMPROVEMENTS.md` tracks bugs A–G with per-bug status and a dismissed-false-positives list |

Documentation defects found: `script/DeployMain.s.sol:51` documents a `CollateralVault.setSwapper` that does not exist; `FUTURE_IMPROVEMENTS.md` and `audit/propeller-audit-*.md` still reference the removed `adminUnwind` path.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 22 (`.t.sol`) + 6 mocks/handlers | File scan |
| Test functions | 73 | File scan |
| Suite result | 22 suites, 72 tests — 71 pass, 1 skip | `forge test` |
| Line coverage | `CollateralVault` 92.09% · `SubLoop` 91.73% · `Harvester` 97.83% · `SyntheticToken` 100% · `DcaDispatch` 73.17% | `forge coverage --ir-minimum` |
| Branch coverage | `CollateralVault` **43.75%** · `SubLoop` 63.16% · `Harvester` 50.00% · `DcaDispatch` 12.50% | `forge coverage --ir-minimum` |
| Function coverage | `CollateralVault` 89.66% · `SubLoop` 93.75% · `Harvester` 100% | `forge coverage --ir-minimum` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 20 files | All five in-scope contracts; deposit, claim, harvest, rebalance, peg, unwind, guardian pause, source control, de-lever/queue interference, SCALE encoding |
| Integration | 2 files | `IntegrationWithdraw.t.sol`, `MultiVaultFlow.t.sol` — full lifecycle against mocks |
| Fork | 0 | none |
| Stateless Fuzz | 1 | one parameterised test; no dedicated fuzz suite |
| Stateful Fuzz (Foundry) | 6 invariants | `PropellerInvariant.t.sol` over `Handler.sol`, 256 runs × 50 calls |
| Stateful Fuzz (Echidna / Medusa) | 0 | none |
| Formal Verification (Lean 4) | ~20 theorems | `formal/PropellerLean` — 0 `sorry`; axioms limited to `propext`/`Classical.choice`/`Quot.sound` |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |
| Scribble Annotations | 0 | none |

### Gaps

1. **No fork tests.** `MockPool` still accrues no interest, hiding the Aave-error-36 deposit path and every accrual-drift scenario. Swap friction *is* modelled — `MockDispatch.setFeeBps` and `MockSwapper.setHaircut` are exercised across ramp, compound and exit by `MultiVaultFlow.t.sol::test_swapCostsReduceRealizedYield` — but both default to zero, so the redemption suite runs frictionless and the `_retireExhaustedHead` write-down is only ever measured at zero slippage.
2. **Branch coverage remains the weakest signal.** 41.30% on `CollateralVault` (up from 38.64%) still leaves most revert paths and stress-side `rebalance` branches unexercised. `Harvester` at 20% has essentially only its happy path.
3. ~~The byte-parity test covers the dead code path.~~ **Closed.** `encodeRouterSell` (pallet 67 — the live path) is now pinned byte-for-byte against runtime metadata for both the deploy and unwind legs, alongside the retired `encodeScheduleSell` reference. Regenerate with `scripts/propeller/gen-router-reference.mjs` after every runtime upgrade; it exits non-zero on pallet-index drift.
4. **Three in-scope externals are never called from any test**: `setTvlCap`, `asset()`, `convertToAssets()`. `SubLoop.setParams` — four unbounded risk parameters — is also uncovered.
5. **No upgrade tests.** Two UUPS proxies with hand-maintained gaps and no reinitializer, and no test performs an upgrade or asserts storage-layout stability — despite a slot having just been deleted.
6. **Invariant handler does not model adversarial config.** The six invariants run against a correctly-wired system; none exercise `harvester == address(0)`, `compoundSlippageBps == 0`, a duplicate `addVault`, or a de-lever concurrent with a queued redemption (the last is now covered by a targeted unit test, not by the fuzzer).

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 20 source-touching commits between 2026-06-05 and 2026-07-31, inside a 550-commit host repo (`money-market`) dating to 2022. Propeller itself is roughly two months old. The working tree additionally carries uncommitted changes not reflected below.

### Contributors

| Author | Source-touching commits | Source Lines (+) | % of Source Changes |
|--------|------------------------:|-----------------:|--------------------:|
| mrq | 13 | +1,854 | 82.8% |
| Yash Sharma | 7 | +384 | 17.2% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors (source) | 2 | Single-dev dominance — one author wrote 83% of in-scope code |
| Merge commits (host repo) | 83 of 550 (15%) | Formal review exists for the host repo; **no propeller-vault commit arrived via a merge/PR** |
| Repo age (propeller source) | 2026-06-05 → 2026-07-31 | ~8 weeks |
| Recent source activity (30d) | 7 commits | Active — a late burst, all of it in security-critical paths |
| Test co-change rate | 80% | 80% of source-changing commits also touched test files (co-modification, not coverage) |
| Fix-without-test rate | 20% | 1 in 5 fix-scored commits shipped without a co-modified test |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `src/CollateralVault.sol` | 14 | Highest churn and the largest contract — prioritise review |
| `src/SubLoop.sol` | 13 | Second-highest churn; carries the loop's entire share and unwind accounting |
| `src/interfaces/ISubLoop.sol` | 5 | Interface reshaped repeatedly during the `IYieldSource` extraction |
| `src/lib/DcaDispatch.sol` | 4 | Encoding corrected twice (owner byte order, DCA→router pivot) |
| `src/Harvester.sol` | 4 | Small file, disproportionate churn |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals: message keywords, diff patterns (deletes code, changes `require`/`assert`, touches access control or accounting), and change shape. **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| `0111f5d` | 2026-06-10 | fix audit bugs A-E + new G, repair test harness | 18 | explicit security language; touches 3 source files |
| `be2dedf` | 2026-07-31 | idempotent rebalance de-lever + capped pokeSettle repay (audit High) | 17 | bug fix in accounting; branch tip |
| `c0f9404` | 2026-06-08 | drop DCA for router.sell — fixes aToken-unpriceable unwind | 15 | **no co-modified test** |
| `449af33` | 2026-07-23 | guardian role fix | 14 | touches access control |
| `02d3a8a` | 2026-06-10 | drop dead dca seam + write-only vars, bump optimizer runs | 14 | deletes code across 3 files |
| `d587521` | 2026-07-24 | yield source change interface + negativeCarry monitor views | 13 | interface + accounting change |
| `27b492c` | 2026-07-23 | prime price from oracle fix | 12 | oracle/pricing |
| `1e1e5ac` | 2026-06-08 | drop KEEPER_ROLE, permissionless keeper ops | 12 | access-control removal across 3 contracts |
| `9e9b840` | 2026-06-08 | borrow against new-collateral delta on deposit (Aave error 36) | 12 | **no co-modified test** |
| `c4d0cce` | 2026-07-21 | claim() partial withdraw bug fix + test | 11 | accounting fix |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 20 | `CollateralVault.sol`, `SubLoop.sol`, `Harvester.sol` |
| oracle_price | 20 | `CollateralVault.sol`, `SubLoop.sol` |
| access_control | 19 | `CollateralVault.sol`, `SubLoop.sol`, `SyntheticToken.sol` |
| state_machines | 19 | `CollateralVault.sol`, `SubLoop.sol` |
| liquidation | 16 | `CollateralVault.sol`, `SyntheticToken.sol` |

Every source commit in the branch touches at least one dangerous area — the codebase is entirely security-critical surface with no inert periphery.

### Technical Debt Markers

The automated scan reports 0 TODO/FIXME/HACK markers. One prose marker remains, in a security-critical path:

| File:Line | Type | Text | Author | Date |
|-----------|------|------|--------|------|
| `SyntheticToken.sol:50` | NOTE | "to hard-restrict transfers to Propeller/Aave addresses, override `_update`… Left as standard ERC20 in the scaffold… revisit before audit." | mrq | 2026-06-05 |

The previous marker at `CollateralVault.sol:674` ("this path … has NOT yet had a final independent audit pass") is gone — the `adminUnwind` path it referred to was deleted.

### Security Observations

- **Single-developer risk**: 83% of in-scope source was written by one author, and **zero propeller-vault commits came through a merge/PR** — every committed change in the 1,041 nSLOC was self-reviewed.
- **The whole codebase is a hotspot.** `CollateralVault.sol` (14 mods) and `SubLoop.sol` (13 mods) together are 80% of the source, and every one of the 20 source commits touches fund flows.
- **Late burst in security-critical paths**: 7 of 20 source commits landed in the final 10 days, and the uncommitted working tree adds a further round of redemption-accounting changes on top. Late changes to redemption accounting are the classic residual-risk pattern.
- **Two committed fix commits shipped without co-modified tests** (`c0f9404`, `9e9b840`). Both are in paths with no fork coverage, so neither has been exercised against real Aave or a real router.
- **`SyntheticToken`'s soulbinding NOTE was deferred "before audit" and never revisited.** The token is a real Aave reserve at LT 9800 with no supply cap; only `MINTER_ROLE` custody keeps it contained.
- **No dependency vendoring boundary.** `foundry.toml` points `libs` at `../hdcl-vault/lib`, so Propeller's OZ and forge-std versions are whatever a sibling project pins, with no lockfile of its own. `foundry.toml:9` acknowledges this.

### Cross-Reference Synthesis

- `CollateralVault.pokeSettle` and `rebalance` are flagged in Section 2, sit in the highest-churn file, and were the subject of both the last committed fix (`be2dedf`) and the largest uncommitted change. That concentration is the single strongest signal for where to focus a review.
- The `formal/` Lean proofs cover deposit isolation, share conservation and the `_creditFreed` weighting, but the model has **no notion of the de-lever/queue interaction or the spiral's termination conditions** — the strongest verification asset in the repo does not reach the code that changed most recently.
- The audit report's leads about the `setYieldSource` drain guard and `adminUnwind` are now moot (both deleted), but its leads about mock fidelity (`MockPool` accrues no interest, `MockDispatch` swaps at zero slippage) remain live and now matter *more*: realized slippage is what sizes the `_retireExhaustedHead` write-down.
- `tasks/proposals/propeller.ts` is stale against the current ABI while `scripts/propeller-wire-lark.mjs` is current — the mainnet-shaped path is the one that has never been exercised.

---

## Changes since the previous x-ray

Uncommitted working-tree changes made after the first x-ray run:

| Change | Files |
|---|---|
| `rebalance()` de-lever capped at non-queued debt and at live loop equity (was 5× over-sized; repaid queued redeemers' own slices and could underflow `syntheticSupplied`) | `CollateralVault.sol` |
| `requestRedeem` rejects a zero-equity source (`NoLoopEquity`) — previously escrowed shares against a zero unwind target and orphaned the request | `CollateralVault.sol` |
| `SubLoop._closeOutUnrealizableUnwinds` + `CollateralVault._retireExhaustedHead` — the spiral hard-stalls once its HF-capped sliver floors to 0 in 6dp aPRIME; the remainder is now written off so the FIFO head can retire | `SubLoop.sol`, `CollateralVault.sol` |
| `adminUnwind()`, `migrationDrainRef`, `MIGRATION_DUST` and the 0.1%-relative drain tolerance removed; `setYieldSource` reduced to a strict deploy-time lever | `CollateralVault.sol` |
| `MockPool` models Aave isolation mode (suppresses auto-enable-as-collateral) | `test/mocks/MockPool.sol` |
| New regression suite for de-lever/queue interference, zero-equity redeem, and spiral termination | `test/DeleverQueueInterference.t.sol` |
| `synthLtBps` removed from storage and the initializer; read LIVE off the reserve config, reverting `SynthReserveNotListed` when unlisted | `CollateralVault.sol` + 15 call sites |
| `setSwapper` added — REQ-SWAP can be repointed without a UUPS upgrade of every vault | `CollateralVault.sol` |
| `harvest()` reverts `HarvesterUnset` instead of paying `msg.sender`; `setHarvester` rejects zero | `SubLoop.sol` |
| `Harvester` registry gains dedup, `removeVault` and `vaultCount()` | `Harvester.sol` |
| `encodeRouterSell` split out and pinned byte-for-byte against live runtime metadata (both legs) | `DcaDispatch.sol`, `test/DcaDispatch.t.sol` |
| New config regression suite | `test/AdminConfig.t.sol` |

Net effect on this report: deferred audit Medium M-2 and two audit leads are resolved by deletion; four Key Attack Surfaces are closed; one self-flagged TODO is gone; the live dispatch encoding is pinned. Branch coverage on `CollateralVault` moved 38.64% → 43.75%, `Harvester` 20.00% → 50.00%, and function coverage 85.19% → 89.66%. Tests went 59 → 72.

Supporting artifacts added outside `src/`: `AUDIT.md` (living finding ledger, 21 tracked ids), `DEPLOYMENT.md` (runbook), `deployments/` (address registry), `../PROPELLER-MAINNET-HANDOVER.md` (10 lark-4 post-mortems), `scripts/propeller/verify-readiness.ts` (75-check read-only gate) and `scripts/propeller/gen-router-reference.mjs`. `tasks/proposals/propeller.ts` was rewritten against the current ABI.

---

## X-Ray Verdict

**FRAGILE** — the invariant and formal-verification layer is unusually strong and the admin surface is now genuinely minimal (no fund-moving or position-unwinding power), but branch coverage sits at 41.30% on the largest contract, there are still no fork tests against the Aave and router integrations the protocol is built on, and every privileged role is held by one address with no timelock.

Tier derivation: Tests = ADEQUATE (unit + stateful fuzz + formal, but zero fork coverage of the primary integration and 41% branch coverage); Docs = HARDENED (thorough NatSpec, strong README, in-repo formal spec index); Access Control = FRAGILE (roles exist and are clear, but no timelock and all five roles on one address). Lowest tier = FRAGILE, and the remaining TODO in `SyntheticToken.sol:50` sits in a security-critical path, which holds it there.

**Structural facts:**
1. 1,041 nSLOC across 5 contracts in 3 subsystems; 2 are UUPS-upgradeable, 2 are not upgradeable at all.
2. 36 entry points — 12 fully permissionless (no role, no caller check), 17 admin/guardian, 5 role-gated to protocol contracts, 1 owner-gated.
3. 22 test files / 73 test functions / 6 stateful invariants at 256×50, plus ~20 machine-checked Lean 4 theorems with 0 `sorry`.
4. All five privileged roles (`DEFAULT_ADMIN`, `ADMIN`, `UPGRADER`, `GUARDIAN`, and via them `MINTER`/`VAULT`) resolve to a single address at `initialize`, with no on-chain delay on any action.
5. Two developers wrote 100% of the committed source over 8 weeks; 83% by one author, and no commit arrived through a pull request.
6. Zero fork tests; the Aave money market, the AaveOracle, the 0x0401 router precompile and the HydraAugustus swapper are all exercised only against mocks — and the swapper is not deployed on mainnet at all.
