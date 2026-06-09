# Propeller — future improvements

Deferred design changes to fold into the **next fresh deploy** (not upgrades —
no storage-layout / UUPS-compatibility constraints apply, so slots and setters
can be removed outright).

## CollateralVault: derive target LTV from the reserve, don't store it

**Today:** `targetLtvBps` (+ `ltvBandLowBps`/`ltvBandHighBps`) are stored uint16s
set by `setLtvBand(...)` (ADMIN/governance). They have to be manually kept in
sync with the money-market reserve's max LTV — drift we've already had to fix by
hand twice (referenda #425-ish and #427). There's no reason for the vault to run
below the reserve max, and no reason for it to be a separate knob.

**Change:** drop the stored target + bands + `setLtvBand` entirely. Read the max
LTV straight off the pool each time:

```solidity
// bits 0-15 of the reserve configuration bitmap = max LTV (bps)
uint256 maxLtv = pool.getConfiguration(collateral).data & 0xFFFF;
```

- `deposit` borrows `collDelta8 * maxLtv / BPS`.
- `rebalance` borrows back up to `maxLtv` when price drift drops utilization
  below it (the only way to exceed max is a collateral price drop, which the
  band/deLever path handles).
- The off-chain `propeller-maxltv-lark.mjs` script becomes unnecessary — the
  vault auto-follows any governance change to the reserve LTV.

**Safety (already validated on lark-2 at 80%):** the vault also supplies
synthetic collateral, so pool borrow capacity is `C·ltv_C + S·ltv_S ≥ C·ltv_C`
— borrowing to the real-collateral max always passes, and Main HF stays
`≥ LT/maxLtv` (tBTC 0.85/0.80 = 1.0625, higher with the synth cushion). The
synthetic HF floor remains the actual liquidation guard.

**Why deferred:** doing it now means leaving the three storage slots as dead
deprecated vars (UUPS layout can't drop them). On a fresh deploy we just delete
them — cleaner. So it waits for the next deploy.

## Synthetic floor is inert: synth reserve LTV=0 ⇒ not counted as collateral

**Found on lark-2.** The synth reserve (`0x23B69fd91a463ECB4B5864e4C2Ec6a20AFEC47b8`)
is configured maxLTV=0, LT=9800. Aave v3 refuses to enable an LTV=0 asset as
collateral (`validateUseAsCollateral` returns false when LTV==0), so the synth
the vault supplies ($52k ETH / $62k tBTC) is **not** in the vault's
`totalCollateralBase` and floors nothing — Main HF is currently held only by the
real collateral. Two consequences:

1. **Synthetic HF floor doesn't work** (the whole "never liquidated" guarantee
   relies on the synth counting as collateral).
2. **`rebalance` is broken on every vault**: it computes
   `ethValue8 = collBase8 − syntheticSupplied`, but the synth was never in
   `collBase8`, so it derives a phantom ~307% LTV → always takes the de-lever
   branch → the Main leg never borrows up to target (both vaults stuck at their
   ~74% deposit LTV; that's why tBTC won't reach 80%).

**Fix on fresh deploy:** give the synth reserve a non-zero LTV (e.g. = its LT, or
a hair under) so it can be enabled as collateral, AND ensure the vault calls
`setUserUseReserveAsCollateral(synth, true)` after its first synth supply
(auto-enable only fires on first supply with LTV>0). Then `collBase8` includes
the synth, `rebalance`'s `ethValue8 = collBase8 − synth` is correct, and the
floor actually floors. Re-test on a fork that models Aave's LTV=0 collateral
exclusion.

## Test harness: ramp path broken + MockPool doesn't model LTV=0 exclusion

Two test-suite gaps surfaced while investigating the above:

- **Ramp is dead at HEAD.** `SubLoopDeploy`, `SubLoopUnwind`, `Harvest`,
  `IntegrationWithdraw`, `KeeperOps::rebalanceDownOnDrop` all fail with
  `equity = 0` — the `MockDcaScheduler` deploy (HOLLAR→PRIME) no longer executes,
  so the loop never builds a position. Correlates with `DcaDispatch`'s
  SCALE-encoding mismatch (`test_encodeMatchesPolkadotJsReference`): the DCA order
  encoding drifted vs the runtime metadata. Repair the encoding + mock so the
  ramp tests (and the new `test_primePriceAppreciationCompoundsToDeposit`) pass.
- **MockPool over-counts collateral.** It sums every aToken balance as collateral
  regardless of the reserve's LTV, so the synth (LTV=0) *looks* like collateral
  in tests — which is exactly why the rebalance bug above is invisible to the
  suite. Make MockPool exclude LTV=0 reserves from `totalCollateralBase` (match
  Aave), which will turn the rebalance bug into a failing test.

## Contract bug audit (2026-06-09) — remedy backlog

Full plan: `~/.claude/plans/nifty-giggling-eclipse.md` (approved, plan-only).
The synth-LTV root cause (above) is bug **B**; the rest of the audit:

### A — [CRITICAL] SubLoop.harvest skims in-flight unwind equity (cross-vault leak)
`harvest()` does `surplus18 = totalEquity()*1e10 - principalEquity` (SubLoop
~L433). On `requestUnwind` the exiter's shares burn and `principalEquity` drops
immediately, but the equity stays in the loop (as aPRIME) until `pokeRepay`
frees it — tracked in `unwindTargetEquity`. So
`totalEquity ≈ principalEquity + carry + unwindTargetEquity`, and harvest's
surplus wrongly includes `unwindTargetEquity`: it withdraws the *exiting vault's
principal* as PRIME → Harvester distributes it to the **current** shareholders
(exiter already burned shares). Breaks `collateral-out ≥ collateral-in`.
Permissionless + looper-called → leaks on any harvest during an open redemption;
amplified by B (rebalance manufactures unwind requests).
**Fix:** `surplus18 = totalEquity*1e10 - principalEquity - unwindTargetEquity`
(clamp ≥ 0); apply to the harvest-threshold check too. `unwindTargetEquity` is
exactly the in-loop unwind notional (shrinks as `_creditFreed` frees equity;
freed HOLLAR → `reservedFreed`, idle, not in `totalEquity`).

### C — [MEDIUM] SubLoop.harvest prices PRIME at $1, over-withdraws
`surplusPrime = surplus18 / 1e12` (SubLoop ~L440) treats PRIME as $1, but
deploy/unwind use the AaveOracle (PRIME ≈ $1.04). Harvest over-withdraws
collateral by the premium, dipping HF below target.
**Fix:** `surplusPrime = surplus18 * pHollar / pPrime / 1e12` (mirror
`_fundDeploy` / `_oracleRate`).

### D — [MEDIUM] SubLoop.deLever is a no-op stub
`deLever` (~L454) only emits → no automated safety de-lever. With B making the
synth floor inert, the loop currently has no liquidation protection if carry
inverts / PRIME depegs. **Fix:** implement the de-lever spiral (unwind machinery,
freed HOLLAR repays loop debt, no payout) sized to restore `targetHf`; keep the
`hf > deLeverTrigger → revert HealthyEnough` guard. (B is the priority.)

### E — [LOW] SubLoop `_unwinders` array never pruned
`_creditFreed` (~L408) loops over `_unwinders`; finished entries (req==0) are
skipped but never removed → unbounded growth → `pokeRepay` gas creep.
**Fix:** swap-remove from `_unwinders` + clear `_isUnwinding` when
`unwindRequested` hits 0 (in `pullFreed`/`_creditFreed`).

### F — [INFO] redemption snapshot ignores interest accrual
`requestRedeem` snapshots `debtShare`/`collateralOwed`/`synthShare`; Main HOLLAR
debt accrues between request and settle, so the exiter repays the snapshot not
the accrued slice (drift stays as Main debt; `maintainPeg` covers the synth
side). Small — flag for auditor.

### Dismissed (false positives)
SubLoop first-depositor share inflation (deposit is VAULT_ROLE-gated; idle-token
donation doesn't move `totalEquity`; pVault uses DEAD_SHARES) · pokeRepay "90%
stalls unwind" (`*90/100/100` = 8dp→6dp decimal conv × 0.9 margin, tranche-capped)
· router-callback reentrancy (nonReentrant + Substrate has no token callbacks).
