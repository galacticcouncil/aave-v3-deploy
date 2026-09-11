# Propeller Smart Contract Audit — Ledger

**Date:** 2026-08-07
**Scope:** `src/CollateralVault.sol`, `src/SubLoop.sol`, `src/Harvester.sol`, `src/SyntheticToken.sol`, `src/lib/DcaDispatch.sol`
**Branch:** `ys-propeller-fixes` (working tree, on top of `0e7f9a4`)
**Test suite:** 72 tests across 22 suites — 71 pass, 1 skip · 6 stateful invariants × 12,800 fuzz calls · ~20 machine-checked Lean 4 theorems (0 `sorry`)

This is a **living ledger**, not a point-in-time report. Every finding keeps its id forever;
new passes reconcile against it rather than starting over. It supersedes the one-shot report at
`audit/propeller-audit-ys-propeller-fixes-20260731.md`, which is retained for provenance and
whose findings are reconciled in [Resolved from the 2026-07-31 pass](#resolved-from-the-2026-07-31-pass).

> AI-assisted review. **No independent human audit has been performed.** HDCL had a Pashov AI
> pass before mainnet (`bil-vault/assets/findings/hdcl-vault-pashov-ai-audit-report-*.md`);
> Propeller has not. This is a launch blocker, not a nice-to-have.

---

## Findings — current state

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| P-01 | HIGH | `rebalance()` de-lever sized off full live debt, repaying queued redeemers' own slices | **FIXED** |
| P-02 | HIGH | `requestRedeem` against a zero-equity source orphans the request | **FIXED** |
| P-03 | HIGH | Unwind spiral hard-stalls, permanently pinning the FIFO head | **FIXED** |
| P-04 | MEDIUM | Permissionless `harvest()` pays the caller when `harvester` is unset | **FIXED** |
| P-05 | MEDIUM | `synthLtBps` stored at init while the real Aave LT is governance-controlled | **FIXED** |
| P-06 | MEDIUM | `Harvester.addVault` has no dedup; one duplicate bricks harvest permanently | **FIXED** |
| P-07 | MEDIUM | No `setSwapper` — repointing REQ-SWAP needs a UUPS upgrade of every vault | **FIXED** |
| P-08 | MEDIUM | `setYieldSource` drain tolerance abandons position-scaled HOLLAR | **REMOVED** (with `adminUnwind`) |
| P-09 | MEDIUM | No fork tests; mocks diverge exactly where the open leads live | **OPEN** |
| P-10 | MEDIUM | No independent human audit | **OPEN** |
| P-11 | LOW | Oracle reads have no zero/staleness guard | **OPEN** |
| P-12 | LOW | De-lever spiral inoperable below HF 1.02 | **OPEN (by design?)** |
| P-13 | LOW | Deposit borrow sized at exactly maxLTV → Aave error 36 on later deposits | **OPEN** |
| P-14 | LOW | `deLever` target has no cancel path when HF recovers | **OPEN** |
| P-15 | LOW | `pokeBorrow` has no unwind inhibit; churns ~2× slippage during a wind-down | **OPEN** |
| P-16 | LOW | `Harvester.harvest` reverts wholesale if any share-holding vault is paused | **OPEN** |
| P-17 | LOW | `totalAssets()` reads live balances; `DEAD_SHARES = 1000` vs 1e6 norm | **OPEN (accepted)** |
| P-18 | LOW | Empty-vault re-entry prices the next depositor 1:1 over residual assets | **OPEN** |
| P-19 | LOW | `SyntheticToken` transfers unrestricted; LT 9800 reserve, no supply cap | **OPEN (accepted)** |
| P-20 | INFO | Storage gaps hand-maintained, no upgrade/layout test | **OPEN** |
| P-21 | INFO | Redemption settles against realized, not snapshot, value | **OPEN (by design)** |

Seven of the eight HIGH/MEDIUM code findings are fixed or removed. The two remaining MEDIUMs
(P-09, P-10) are process, not code, and both gate mainnet.

---

## Fixed this pass

### P-01 — `rebalance()` de-lever cannibalised queued redeemers' debt · HIGH

**Location:** `CollateralVault.rebalance` (de-lever branch)

`adminUnwind` sized its target as `debt − totalQueuedDebt` precisely so it never repaid debt a
queued redeemer's snapshot would repay itself. `rebalance()`'s de-lever branch had no such
subtraction — it sized off the full live debt, which includes every queued `debtShare`.

Measured on a 90%-queued vault after a 50% collateral drop: live debt 2250 HOLLAR, queued 2025,
non-queued 225, and `deleverTarget` **1125** — a 5× over-size that repays 900 HOLLAR of the
redeemer's own slice out of the shared freed-HOLLAR bucket, ahead of the FIFO queue. `r.repaid`
then never reaches `r.debtShare`, `queueHead` never advances, and every request behind it is
blocked. The same over-size burns synthetic off the whole book while each queued request holds
a pre-burn `synthShare` snapshot; once `deleverTarget/debt + queuedFraction > 1` the queue arm's
`syntheticSupplied -= synthRel` underflows and bricks every redemption.

**Fix:** two caps — at the non-queued Main debt (rounding the queued amount *up* into 8dp so the
cap errs in the queue's favour) and at the vault's live loop equity, so the target can never
exceed what the unwound slice can actually free.
**Regression:** `DeleverQueueInterference.t.sol::test_rebalanceDeleverIsCappedAtNonQueuedDebt`.

### P-02 — zero-equity redemption orphans the request · HIGH

**Location:** `CollateralVault.requestRedeem` / `SubLoop.requestUnwind`

`requestUnwind` derives its release target from live equity with no zero check. Redeeming while
the loop is un-ramped (PRIME is an isolation-mode reserve, so a plain supply never auto-enables
it as collateral — `totalEquity()` reads 0) recorded a **zero** unwind target while the vault
escrowed shares and enqueued a real `debtShare`. Nothing would ever be freed for it.

**Observed in production** on lark-4, 2026-07-31: a pre-ramp redeem left an orphaned request #0.

**Fix:** `requestRedeem` reverts `NoLoopEquity` when `yieldSource.equityOf(vault) == 0`.
`pokeBorrow` is permissionless, so a caller who hits this can ramp and retry in the same block.
The guard is on the vault, not the loop — only the vault knows there is a user to strand.
**Regression:** `test_requestRedeemBeforeRampRecordsZeroUnwindTarget`,
`test_subLoopRequestUnwindStillPermissiveAtZeroEquity`.

### P-03 — unwind spiral hard-stalls, pinning the FIFO head · HIGH

**Location:** `SubLoop.pokeRepay` / `CollateralVault.pokeSettle`

Not slow convergence — a fixed point. `pokeRepay` may only sell the sliver that keeps HF above
`STEP_HF_FLOOR` (1.02); once that sliver floors to zero in 6dp aPRIME the budget can only
shrink and the position never moves again. State was byte-identical at 2,000 and 6,000 rounds
with `unwindTargetEquity` pinned at 6.71e12 wei — measured with a **frictionless** mock, so
this is pure 8dp/6dp truncation before any real slippage.

Left open, `r.repaid` never reaches `r.debtShare`: the head never retires, every request behind
it is blocked forever, the redeemer's last sliver of collateral is never released, and
`setYieldSource`'s drain guard can never be satisfied.

**Fix:** `SubLoop._closeOutUnrealizableUnwinds` writes the unrealizable remainder off on a
*proven-permanent* stall (HF headroom existed but the sliver truncated to zero) or a fully
drained position — never on a temporary HF block, which a price move can reopen.
`CollateralVault._retireExhaustedHead` then snaps the head's `debtShare` down to `repaid` once
the source owes the vault nothing. See P-21 for the economics.
**Regression:** `test_unwindSpiralTailIsRetiredNotStalled`.

### P-04 — permissionless `harvest()` paid the caller when unset · MEDIUM

`initialize` never assigns `harvester`, and `SubLoop.harvest` fell back to `msg.sender` when it
was `address(0)` — making the entire accrued loop carry claimable by anyone in the
deploy→wiring window, contradicting the `IYieldSource.harvest` natspec.

**Fix:** reverts `HarvesterUnset` instead; `setHarvester` rejects zero so it cannot be re-zeroed.
**Regression:** `AdminConfig.t.sol::test_harvestFailsClosedWhileHarvesterUnset`.

### P-05 — `synthLtBps` was a stale copy of a governance parameter · MEDIUM

INV-1 — the un-liquidatable-principal guard — is checked as
`syntheticSupplied · synthLtBps ≥ mainDebt` against **vault storage**. `synthLtBps` was set once
at `initialize` while the real value is the Aave reserve's liquidation threshold, which
governance can retune at any time. A stale-high copy lets the guard pass while the real floor no
longer covers the debt. This is the same drift class the team already eliminated for
`targetLtvBps`.

**Fix:** removed from storage and from the initializer; `synthLtBps()` now reads bits 16-31 of
`pool.getConfiguration(synthetic)` live, mirroring `_maxLtvBps()`. Reverts
`SynthReserveNotListed` when the reserve has no LT yet, instead of panicking on a division by
zero. **Regression:** `test_synthLtFollowsGovernance`, `test_depositFailsClosedBeforeSynthReserveIsListed`.

### P-06 — `Harvester` registry had no dedup and no removal · MEDIUM

`harvest()` sums `sharesOf(v)` per registry entry and hard-requires the total to equal
`subLoop.totalShares()`. A vault listed twice double-counts, fails that check, and reverts every
harvest — permanently, because `Harvester` is not upgradeable.

**Fix:** `isRegistered` mapping rejects duplicates; `removeVault` swap-removes; `vaultCount()`
exposes the registry. **Regression:** `test_addVaultRejectsDuplicates`,
`test_removeVaultKeepsRegistryConsistent`.

### P-07 — swapper was immutable after `initialize` · MEDIUM

`script/DeployMain.s.sol:51` documented a `CollateralVault.setSwapper` that did not exist, and
`SWAPPER` defaults to the governance precompile placeholder. REQ-SWAP (HydraAugustus) is not
deployed on mainnet, so repointing would have required a UUPS upgrade of every vault.

**Fix:** `setSwapper(address)` under `ADMIN_ROLE` with a zero-check. Safe to rotate at any time —
the swapper never custodies vault funds across calls. **Regression:** `test_setSwapperRepointsWithoutUpgrade`.

### P-08 — `setYieldSource` drain tolerance · MEDIUM → **REMOVED**

The guard accepted `pending ≤ 1e18 || pending·1000 ≤ migrationDrainRef`, where
`migrationDrainRef` was the full unwound position equity — so the relative branch tolerated
abandoning **0.1% of notional** (≈1,000 HOLLAR on a 1M position) that `SubLoop` has no sweep to
recover.

**Resolution:** `adminUnwind()`, `migrationDrainRef` and `MIGRATION_DUST` were removed entirely
at the maintainer's direction (the emergency wind-down was future scope and added complexity).
`setYieldSource` is now a strict deploy-time lever requiring `pendingUnwindOf == 0` exactly.
This also dissolves two of the 2026-07-31 leads. See P-22 note below.

---

## Open findings

### P-09 — no fork tests; mocks diverge where the leads live · MEDIUM

`MockPool` accrues **no interest**. That hides P-13 and every accrual-drift path, and it is the
divergence four separate leads in the 2026-07-31 report point at when they say "tests miss it".

Swap slippage is better covered than that report implies: `MockDispatch.setFeeBps` +
`MockSwapper.setHaircut` are exercised end-to-end by
`MultiVaultFlow.t.sol::test_swapCostsReduceRealizedYield`, which asserts the fee holes land in
the right places across ramp, compound **and** exit ("settles slightly under the snapshot,
still > principal"). The residual gap is that both default to zero, so every *other* test —
including the whole redemption suite — runs frictionless, and the P-03/P-21 write-down is only
ever measured at zero slippage.

`MockPool` now models Aave isolation mode (added while proving P-02), which closed the
divergence that hid P-02 entirely.

**Fix:** a `--fork-url` suite against live Aave + the real router; interest accrual in
`MockPool`; and a non-zero *default* fee so the settlement paths inherit friction rather than
opting into it.

### P-10 — no independent human audit · MEDIUM

The in-repo report is AI-assisted and says so in its own footer. HDCL had a Pashov AI pass
before mainnet. **Launch blocker.**

### P-11 — oracle reads unvalidated · LOW

`SubLoop._oracleRate` and `CollateralVault._fairCollateralOut` consume `getAssetPrice` with no
zero, staleness or deviation check. Asymmetric: `pPrime == 0` reverts on division (fail-closed),
`pHollar == 0` silently collapses `minOut` to 0 (fail-open). Reaching it needs an oracle
misconfiguration no unprivileged actor controls, but the guard is two lines.

### P-12 — de-lever inoperable below HF 1.02 · LOW (design question)

`pokeRepay`'s sell gate is `coll8 > minColl8` with `minColl8` holding HF at `STEP_HF_FLOOR`.
Below that the gate never opens, so `deLever()` can set a target `pokeRepay` can never drain and
an in-flight redemption frees nothing. Demonstrated: PRIME −50% ⇒ `repaid == 0`.

Arguably correct — the loop is the risk sink, user principal is floored by the synthetic and
un-liquidatable, and Aave liquidating the loop is the intended backstop. **But it is nowhere
documented as a deliberate choice.** Decide and write it down.

### P-13 — deposit borrow sized at exactly maxLTV · LOW

`CollateralVault.deposit` borrows exactly `maxLtv` of the collateral delta with no
`availableBorrowsBase` haircut, so accrued HOLLAR interest can tip a later deposit into Aave
error 36 (`COLLATERAL_CANNOT_COVER_NEW_BORROW`). Fail-closed liveness only. Untestable until
P-09 lands.

### P-14 — `deLever` target cannot be cancelled · LOW

`deleverDebtTarget` is monotone (`if (x18 <= deleverDebtTarget) revert`) with no path to clear
it if HF recovers, so `pokeRepay` keeps de-levering a position that is no longer unhealthy.
Value-neutral; costs slippage and yield.

### P-15 — `pokeBorrow` has no unwind inhibit · LOW

No `unwindTargetEquity`/`deleverDebtTarget` guard, unlike `pokeRepay`. Extraction and DoS were
refuted in the 2026-07-31 pass; residual is ~2× `dcaSlippagePpm` of bounded, non-compounding
dust when re-levering against an in-flight unwind. Optional hardening.

### P-16 — a paused vault blocks the shared harvest · LOW

`Harvester.harvest` calls each vault's `whenNotPaused` `compound()` inside a loop with a strict
`registeredShares == totalShares` requirement. A guardian pause on one vault reverts the whole
shared harvest for every healthy vault. `removeVault` (P-06) now provides an escape hatch, but
per-vault `try/catch` would be cleaner.

### P-17 — `totalAssets()` reads live balances · LOW (accepted)

`collateralAToken.balanceOf + collateral.balanceOf`. The raw-balance term is required for
settle→claim rate stability, but it makes the share price movable by direct transfer with only
`DEAD_SHARES = 1000` (industry norm 1e6) resisting it. The classic inflation attack is
unprofitable — an attacker holding 1/1001 of supply recovers ~0.1% of any donation — so this is
a defensive note, not a live vector.

### P-18 — empty-vault re-entry · LOW

`_previewShares` takes the `supply == 0` branch whenever `totalSupply()` is 0, including after a
full exit that left residual `totalAssets`. The next depositor is priced 1:1 and captures the
residual. Residual should be dust; unbounded in principle.

### P-19 — `SyntheticToken` transfers unrestricted · LOW (accepted)

A real Aave reserve at LT 9800 with no supply cap; only `MINTER_ROLE` custody keeps it
contained. The soulbinding note at `SyntheticToken.sol:50` was deferred "before audit" and never
revisited — decide explicitly before mainnet.

### P-20 — storage gaps unverified · INFO

`CollateralVault.__gap` is `uint256[39]` and `SubLoop.__gap` is `uint256[40]`, both maintained by
hand — the vault's was just adjusted 38 → 39 when `migrationDrainRef` was deleted. **Deleting a
storage variable is safe for a fresh deploy and fatal for an upgrade over the live lark
proxies**, and nothing in the repo enforces the distinction. No `forge inspect storage` diff, no
OZ upgrade validation, no upgrade test.

### P-21 — settlement is against realized, not snapshot, value · INFO (by design)

`_retireExhaustedHead` snaps a head request's `debtShare` down to what the spiral actually
realized once the source is exhausted. `debtShare` is an oracle-marked snapshot while settlement
is funded by realized HOLLAR; the two never agree to the wei. Measured 1.3e-11 relative at zero
slippage; real slippage and negative carry widen it.

The redeemer bears the shortfall, which is the correct economics — they own their own slice's
loop P&L — and because collateral is released strictly proportionally to `repaid/debtShare`,
bearing it means receiving proportionally less, never taking someone else's. **The write-down is
gated on source exhaustion, not on the shortfall being small**, so under sustained negative
carry it can be material. Flag for the external auditor.

---

## Resolved from the 2026-07-31 pass

| Prior finding | Resolution |
|---|---|
| **1. Non-idempotent `rebalance()` de-lever bricks `pokeSettle`** (high) | **RESOLVED** in `be2dedf` (effective-debt sizing + `min(availableHollar, deleverTarget, debtNow)` cap). The *queued-debt* half of the same interaction was still open — now **P-01**, fixed. |
| **2. `setYieldSource` 0.1%-relative drain tolerance** (medium) | **REMOVED** — see P-08. The guard, `migrationDrainRef` and `adminUnwind` are all gone. |
| **3. Permissionless `harvest()` pays caller when harvester unset** (medium) | **RESOLVED** — now P-04, fixed. |
| Lead: `totalQueuedDebt` not seeded on UUPS upgrade → `pokeSettle` underflow | **OPEN as P-20.** Still no reinitializer; the slot now also feeds P-01's cap, so a stale 0 mis-sizes the de-lever as well. |
| Lead: `adminUnwind` + drain-guard lock non-redeeming holders | **REMOVED** with `adminUnwind`. |
| Lead: `setYieldSource` strands still-freeable HOLLAR when the loop retains other vaults' aPRIME | **REMOVED** with the relative drain branch. |
| Lead: `pokeSettle` applies freed bucket to `deleverTarget` before the FIFO queue (priority inversion) | **OPEN, reduced.** P-01's caps bound how much can be diverted, so it can no longer starve the queue indefinitely — but de-lever still consumes before the queue. Latency-only. |
| Lead: negative-carry redemptions cannot fully settle; tail pins `totalQueuedDebt` | **RESOLVED** by P-03's write-down. The lead was understated: the stall happens at **zero** slippage, not only under negative carry. |
| Lead: `pokeBorrow` lacks an unwind/de-lever inhibit | **OPEN as P-15** (extraction/DoS refuted; dust residual only). |
| Lead: AaveOracle reads have no zero/staleness guard | **OPEN as P-11.** |
| Lead: incremental deposits at exactly maxLTV can brick further deposits (Aave error 36) | **OPEN as P-13.** |
| Lead: shared `Harvester.harvest` reverts if a share-holding vault is paused | **OPEN as P-16**, with `removeVault` added as an escape hatch. |

---

## Test posture

| Metric | Value |
|---|---|
| Tests | 72 across 22 suites — 71 pass, 1 skip |
| Stateful invariants | 6 × 256 runs × 50 calls = 76,800 checks |
| Formal (Lean 4) | ~20 theorems, 0 `sorry`, axioms limited to `propext`/`Classical.choice`/`Quot.sound` |
| Line coverage | `CollateralVault` 92.09% · `SubLoop` 91.73% · `Harvester` 97.83% · `SyntheticToken` 100% · `DcaDispatch` 73.17% |
| Branch coverage | `CollateralVault` 43.75% · `SubLoop` 63.16% · `Harvester` 50.00% · `DcaDispatch` 12.50% |
| Function coverage | `CollateralVault` 89.66% · `SubLoop` 93.75% · `Harvester` 100% |
| Fork tests | **0** |

Branch coverage remains the weakest signal and is the clearest place to spend effort after the
fork suite. `DcaDispatch` at 12.5% branches is misleading — its live encoding path is now pinned
byte-for-byte against runtime metadata (`test_routerSellUnwindLegMatchesRuntimeMetadata`,
`test_routerSellDeployLegMatchesRuntimeMetadata`); the uncovered branches are the compact-integer
modes for route lengths ≥ 64, which cannot occur.

---

## Recommendations, by leverage

| Priority | # | Action | Effort |
|---|---|---|---|
| 1 | P-10 | Commission an independent audit | external |
| 2 | P-09 | Fork suite + interest-accruing `MockPool` + non-zero `MockDispatch` fee | ~2 days |
| 3 | P-20 | Storage-layout test + a reinitializer decision before any upgrade | ~half a day |
| 4 | P-11 | Zero/staleness asserts in `_oracleRate` and `_fairCollateralOut` | ~1 hour |
| 5 | P-12 | Decide and document the sub-1.02 behaviour | doc + decision |
| 6 | P-21 | Have the external auditor rule on the write-down semantics | review |
| 7 | P-13 | Haircut the deposit borrow below live `availableBorrowsBase` | ~2 hours |
| 8 | P-16 | Per-vault `try/catch` in `Harvester.harvest` | ~1 hour |
| 9 | P-14, P-15 | Cancel path for `deleverDebtTarget`; unwind inhibit on `pokeBorrow` | ~2 hours |
| 10 | P-19 | Decide on synthetic soulbinding | decision |
| — | P-17, P-18 | Accepted; revisit if `totalAssets` accounting changes | — |
