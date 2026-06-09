# Propeller — future improvements

Backlog + status for the contract-audit remedies (2026-06-09 audit, implemented
2026-06-10 on this branch). The contracts here are **fresh-deploy source** —
CollateralVault dropped storage slots (no UUPS compat with the live lark-2
proxies); SubLoop stayed **append-only** so the live loop can be upgraded to
pick up the A/C/E/G fixes + deLever.

## Implemented (this branch, suite green)

- **A [CRITICAL] harvest skimmed in-flight unwind equity** — `surplus18` now
  subtracts `unwindTargetEquity` (exiters' equity awaiting the spiral is not
  carry). Regression: `Harvest.t.sol::test_harvestSkipsInFlightUnwindEquity`.
- **B [CRITICAL] synth LTV-0 ⇒ floor inert + rebalance phantom** — vault-side:
  `_supplySynth` (deposit/rebalance/maintainPeg) explicitly calls
  `setUserUseReserveAsCollateral(synth, true)` (try/catch tolerates an LTV-0
  listing); scripts: synth listed LTV **100 bps** (`tasks/proposals/propeller.ts`,
  `scripts/propeller-wire-lark.mjs`). Regressions: `SynthLtvZero.t.sol` (models
  the live misconfiguration AND the governance recovery path).
- **C [MEDIUM] harvest priced PRIME at $1** — `surplusPrime` sized via
  `_oracleRate` (mirrors `_fundDeploy`). Regression:
  `Harvest.t.sol::test_primePriceAppreciationCompoundsToDeposit` (+6% PRIME →
  compounds ~27.8% onto a 1 ETH deposit, HF stays at target).
- **D [MEDIUM] deLever stub** — implemented: sizes
  `x = (targetHf·debt − lt·coll)/(targetHf − lt)` into `deleverDebtTarget`
  (appended storage, slot 379); `pokeRepay` runs the spiral while it's open and
  repays loop debt with the FULL proceeds (no payout) before the proportional
  split. Regression: `SubLoopUnwind.t.sol::test_deLeverRestoresTargetHf`.
- **E [LOW] `_unwinders` unbounded** — `pullFreed` swap-removes a finished
  unwinder (+ clears `_isUnwinding`); re-requests re-register. Regression:
  `SubLoopUnwind.t.sol::test_unwinderPrunedAfterFullPull`.
- **G [CRITICAL, found by the repaired harness] `_creditFreed` over-credits** —
  it weighted by `unwindRequested` (shrinks on *pull*) against
  `unwindTargetEquity` (shrinks on *credit*): after any credit-without-pull
  round, `req/target > 1` ⇒ Σcut > freed ⇒ `reservedFreed` overstates the
  loop's HOLLAR ⇒ pulls revert / spiral stops early. Now weights+caps by
  `unwindRequested − freedHollar` (Σ == target). The old suite was green only
  because the dead harness never built a position. Live on lark-2 (pokeRepay +
  the B-manufactured unwinds) — include in the SubLoop upgrade with A/C/E.
- **targetLtv no longer stored/configurable** — the vault reads the reserve max
  LTV live (`pool.getConfiguration(collateral) & 0xFFFF`); `targetLtvBps` /
  bands / `setLtvBand` and the initializer arg are gone (initialize is now
  13 args — deploy scripts updated). Hysteresis is constants (−500/+300 bps).
  `scripts/propeller-maxltv-lark.mjs` is obsolete for fresh deploys.
  Regression: `KeeperOps.t.sol::test_rebalanceFollowsGovernanceLtvChange`.
- **Test harness repaired** — `MockDispatch` (SCALE-decoding router mock)
  etched at the 0x0401 dispatch precompile executes the deploy/unwind legs with
  real route semantics; `MockPool` now models Aave's use-as-collateral flag
  (auto-enable only on first supply and only when LTV>0; LTV-0 balances are
  NOT collateral) + `getConfiguration`. `MockDcaScheduler` is no longer used.
  The DcaDispatch reference encoding was corrected: the original polkadot.js
  snippet derived the owner AccountId32 address-first, but
  pallet-evm-accounts::truncated_account_id is `b"ETH\0" ++ addr ++ 8×00`
  (hydration-node lib.rs:553) — the library was right, the reference wasn't.

## Open — lark-2 (live testnet) remediation

1. **Run the interim referendum**: `scripts/propeller-synth-ltv-lark.mjs --live`
   (synth reserve LTV 0 → 100 bps; one Root call). NOT retroactive — see next.
2. **Live positions don't retro-enable**: the two vaults supplied synth under
   LTV 0, so the bump engages only on their NEXT synth supply. Live vaults run
   the OLD impl (no `_supplySynth` enable) → either upgrade the vault impl
   (storage-compatible variant of the enable only) or redeploy fresh. The
   manufactured `deleverTarget`/unwind backlog on the tBTC vault also needs
   draining (pokeSettle after the spiral) or a redeploy.
3. **Upgrade the live SubLoop** (append-only ✓) to pick up A/C/E/G + deLever.
4. **Looper mitigation until then**: gate `harvest()` calls on
   `unwindTargetEquity() == 0` — any harvest during an open redemption leaks
   (A), and B keeps redemptions open. (Or just pause the looper's harvest leg.)

## Open — product / deploy

- **REQ-DISCOUNT unimplemented** — real net carry is ~8.6%
  (maxLtv·loopLeverage·spread); the ~22% headline assumes the redemption
  discount mechanism, which doesn't exist yet. Implement or stop quoting it.
- **PRIME mirror oracle owned by the looper hot key** (lark-2:
  0xbd1108369553bfFBAaa1BA5C8D07a8131EB92F10, owner = looper key). Fine for
  testnet; fresh/mainnet deploy: owner = governance, bot key behind an updater
  role on ManagedOracle.
- **F [INFO] redemption snapshot ignores interest accrual** — `requestRedeem`
  snapshots `debtShare`/`collateralOwed`/`synthShare`; Main HOLLAR debt accrued
  between request and settle stays as Main debt (covered by `maintainPeg` on
  the synth side). Small — flag for the auditor.
- `Deploy.s.sol` post-deploy console notes still mention KEEPER_ROLE grants
  (removed) — cosmetic.

### Dismissed (false positives)
SubLoop first-depositor share inflation (deposit is VAULT_ROLE-gated; idle-token
donation doesn't move `totalEquity`; pVault uses DEAD_SHARES) · pokeRepay "90%
stalls unwind" (`*90/100/100` = 8dp→6dp decimal conv × 0.9 margin, tranche-capped)
· router-callback reentrancy (nonReentrant + Substrate has no token callbacks).
