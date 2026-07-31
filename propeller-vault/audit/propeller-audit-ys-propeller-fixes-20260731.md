# Security Review — Propeller (propeller-vault) — branch ys-propeller-fixes

## Scope
| | |
|---|---|
| Mode | propeller-vault/src + Aave seams; branch diff heaviest |
| Files | CollateralVault.sol - SubLoop.sol - Harvester.sol - SyntheticToken.sol - lib/DcaDispatch.sol - interfaces/* |
| Baseline | forge test green (57 pass / 1 skip, 6 invariant suites) |

## Findings

[85] **1. Non-idempotent rebalance() de-lever lets a permissionless caller over-unwind the loop and brick pokeSettle (redemption DoS)**  (high, core)
`CollateralVault.rebalance` - Confidence: 85
**Description** rebalance()'s de-lever branch is permissionless and non-idempotent — it reads LTV live and only queues an unwind and increments deleverTarget without repaying Main debt, so ltvBefore is unchanged and the branch re-fires every call, unwinding the entire loop position and inflating deleverTarget past live debt; pokeSettle then repays deleverTarget ahead of the FIFO queue with no min-with-debtNow cap, driving debt to 0 and reverting every subsequent pokeSettle (NO_DEBT, or `syntheticSupplied -= synthBurn` underflow when r>debtNow), permanently freezing all redemptions.
**Fix**
```diff
- // de-lever branch: queues unwind + accumulates deleverTarget off live LTV
- loopShares -= sliceShares;
- yieldSource.requestUnwind(sliceShares);
- deleverTarget += repay8 * 1e10;
+ // subtract already-queued de-lever from live debt so the branch is idempotent
+ uint256 pendingRepay8 = deleverTarget / 1e10;
+ if (debtBase8 > pendingRepay8) debtBase8 -= pendingRepay8; else return;
+ // ...recompute repay8 against reduced debtBase8; require(deleverTarget == 0) or per-block cooldown
+ loopShares -= sliceShares;
+ yieldSource.requestUnwind(sliceShares);
+ deleverTarget += repay8 * 1e10;

  // pokeSettle: cap repayment so it can never over-repay
- uint256 r = availableHollar < deleverTarget ? availableHollar : deleverTarget;
+ uint256 r = availableHollar < deleverTarget ? availableHollar : deleverTarget;
+ if (r > debtNow) r = debtNow; // never revert NO_DEBT / underflow synthBurn
```
---

[75] **2. setYieldSource 0.1%-relative drain tolerance strands position-scaled HOLLAR in the abandoned yield source**  (medium, branch)
`CollateralVault.setYieldSource` - Confidence: 75
**Description** The drain guard accepts `pending <= MIGRATION_DUST(1e18) || (migrationDrainRef != 0 && pending*1000 <= migrationDrainRef)`, and migrationDrainRef is the full unwound position equity snapshotted at adminUnwind — so the relative branch tolerates abandoning up to 0.1% of the original notional (e.g. ~1,000 HOLLAR on a 1,000,000 HOLLAR position) while it is still owed; after repoint the vault only pulls the new source, SubLoop has no sweep, and migrationDrainRef is reset to 0 so the residual becomes permanently un-pullable without a UUPS upgrade. Admin-gated and bounded, but scales with vault size rather than the sub-1-HOLLAR dust the comment claims. Promoted from LEAD on independent agreement across four lenses.

---

[75] **3. Permissionless SubLoop.harvest() pays the entire loop carry to the caller when harvester is unset (address(0))**  (medium, core)
`SubLoop.harvest` - Confidence: 75
**Description** harvest() is permissionless and initialize() never assigns `harvester` (defaults to address(0)); line 495 routes the full skimmed surplusPrime to `msg.sender` when unset, contradicting the IYieldSource invariant that carry never routes to the caller, and setHarvester has no zero-check so admin can re-zero it. A profitable trigger needs accrued carry above the 0.1% threshold to exist while harvester is still address(0) — a deploy-ordering/misconfiguration window — but nothing fails closed. Promoted from LEAD on independent agreement across three lenses.

---

Findings List
| # | Conf | Sev | Branch? | Title |
|---|---|---|---|---|
| 1 | 85 | high | core | Non-idempotent rebalance() de-lever bricks pokeSettle (redemption DoS) |
| 2 | 75 | medium | branch | setYieldSource 0.1%-relative drain tolerance strands position-scaled HOLLAR |
| 3 | 75 | medium | core | Permissionless harvest() pays carry to caller when harvester unset |

## Leads
- **totalQueuedDebt not seeded on UUPS upgrade -> pokeSettle underflow** — `CollateralVault.pokeSettle` — Code smells: appended storage slot with no reinitializer/migration; unguarded `totalQueuedDebt -= repayNow` — Upgrading a live proxy while the queue holds active requests leaves the new slot at 0; the first settle of a queued slice computes `0 - repayNow` and reverts, bricking FIFO settlement until a further governance upgrade. Privileged-omission trigger, governance-recoverable. The self-flagged accrual-drift underflow is REFUTED (repayNow capped at debtShare-repaid).
- **adminUnwind + drain-guard mis-calibration can lock non-redeeming holders** — `CollateralVault.setYieldSource / adminUnwind` — Code smells: 0.1% drain tolerance tighter than the 1% swap slippage the loop tolerates; no bare-collateral exit while paused — realized proceeds fall short of oracle-marked unwindRequested by up to the tolerated slippage + accrued interest, so pending converges above both thresholds; the vault stays paused with the only restore path blocked by an unsatisfiable guard. Admin-induced, recoverable via UUPS upgrade; mocks swap at zero slippage so tests miss it.
- **pokeSettle applies the shared freed bucket to deleverTarget before the FIFO queue (priority inversion)** — `CollateralVault.pokeSettle` — Code smells: single commingled freedHollar bucket; deleverTarget consumed strictly before the queue loop — a redeemer's own freed slice can be diverted to de-lever/admin debt first, delaying redemptions through a sustained decline. Latency-only, no value lost, not profitably griefable.
- **setYieldSource can strand still-freeable HOLLAR when the loop retains other vaults' aPRIME** — `CollateralVault.setYieldSource` — Code smells: top-of-function pullFreed captures freed-so-far but not future frees; relative branch with no absolute cap — repoint while unwindRequested>0 leaves later pokeRepay crediting freedHollar in the OLD loop that the repointed vault never pulls. Admin-gated, recoverable by re-pointing back.
- **Negative-carry redemptions cannot fully settle; tail pins totalQueuedDebt and under-sizes deleverTarget** — `CollateralVault.pokeSettle` — Code smells: head-advance test `if(r.repaid >= r.debtShare)` unreachable when freed equity < snapshot debtShare; no keeper top-up — the under-funded tail stays active and its residual pins totalQueuedDebt forever, under-sizing adminUnwind's deleverTarget. Inherent async valuation-vs-realized economics; also independently refutes the self-flagged totalQueuedDebt underflow.
- **pokeBorrow lacks an unwind/de-lever inhibit; permissionless re-lever churns dust slippage** — `SubLoop.pokeBorrow` — Code smells: no unwindTargetEquity/deleverDebtTarget guard unlike pokeRepay — extraction/DoS claims REFUTED (pays caller nothing; no-op below targetHf; pokeRepay's 1.02 floor is below pokeBorrow's 1.05 so headroom is preserved and equity conserved). Residual: ~2x dcaSlippagePpm dust bleed on the appreciated sliver during an unwind. Optional hardening only.
- **AaveOracle reads have no zero-price/staleness guard; HOLLAR price 0 collapses router min-out to 0** — `SubLoop._fundDeploy / _oracleRate` — Code smells: getAssetPrice consumed with no `!=0`/freshness assertion; numerator-zero silently disarms slippage protection while denominator-zero fail-closes — reaching pHollar==0 requires an oracle mis-config no unprivileged actor controls for a configured $1 reserve. Missing defensive guard, not a forced sandwich.
- **Incremental deposits sized at exactly maxLTV of the delta can brick further deposits (Aave error 36)** — `CollateralVault.deposit` — Code smells: borrow sized off `(collAfter8-collBefore8)*maxLtv` exactly, synth reserve LTV 0 adds no borrow power, no availableBorrowsBase haircut — accrued variable-debt HOLLAR interest tips aggregate debt past borrow power, reverting validateBorrow. Fail-closed liveness only, conditional on nonzero borrow rate; pre-existing; MockPool accrues no interest so tests miss it.
- **Shared Harvester.harvest() reverts wholesale if a share-holding vault is paused by the guardian** — `Harvester.harvest` — Code smells: per-vault compound() is whenNotPaused inside a shared loop with strict `require(registeredShares==total)` — the adminUnwind-triggered DoS is REFUTED (adminUnwind zeroes loop shares so cut=0 => `continue` before compound), but a bare guardian pause() leaves shares>0 and reverts the whole shared harvest. Pre-existing, privileged trigger, liveness-only.

> AI-assisted review; not a guarantee of security. Recommend an independent human pass before mainnet.

---

## Appendix — full lead detail

### totalQueuedDebt not seeded on UUPS upgrade -> pokeSettle underflow bricks settlement on an upgraded live vault
- **Location:** CollateralVault.pokeSettle (CollateralVault.sol:414)
- **Code smells:** freshly appended storage slot with no reinitializer/migration; unguarded checked subtraction totalQueuedDebt -= repayNow
- **Note:** No reinitializer exists (only initialize under initializer, line 170); totalQueuedDebt is an appended slot (line 125) incremented only by the new requestRedeem (line 357). Upgrading a live proxy (tBTC/lark scripts confirm live impls) while the redemption queue holds active requests leaves the new slot at 0 while the queue is non-empty; the first pokeSettle that repays a queued slice computes 0 - repayNow and reverts, bricking FIFO settlement until a further governance upgrade+migration. Gated because the state requires a privileged UPGRADER shipping an upgrade with an open queue rather than draining first, and it is governance-recoverable. NOTE: the separately self-flagged accrual-drift underflow is REFUTED (repayNow capped at remainingDebt=debtShare-repaid, lines 389/398, with repaid bumped in lockstep at 413, so per-request sum repayNow <= debtShare and a fresh vault never underflows).

### adminUnwind + drain-guard mis-calibration can lock non-redeeming holders until a governance upgrade
- **Location:** CollateralVault.setYieldSource / adminUnwind (CollateralVault.sol:698)
- **Code smells:** drain tolerance (0.1%) tighter than the swap slippage (1% dcaSlippagePpm) the loop itself tolerates; no bare-collateral exit while paused
- **Note:** requestUnwind marks unwindRequested at oracle-marked slice value while _creditFreed/pullFreed decrement by realized HOLLAR; realized proceeds fall short by up to the tolerated swap slippage (~1%) plus accrued loop-debt interest, so pendingUnwindOf converges to a residual larger than both drain thresholds (1e18 absolute and migrationDrainRef/1000 relative). adminUnwind's _pause() then holds: deposit/requestRedeem/rebalance are whenNotPaused with no bare-collateral exit, and setYieldSource->unpause->rebalance is the only restore path, blocked by the unsatisfiable drain guard. Holders who did not pre-queue a redemption are locked until governance performs a UUPS upgrade. Admin/governance-induced and recoverable, in an explicitly-unaudited emergency path. Tests miss it because MockDispatch swaps at exactly oracle rate (zero slippage) and MockPool accrues no interest, so residual is sub-1e18 dust.

### pokeSettle applies the shared per-vault freed bucket to deleverTarget before the FIFO redemption queue (priority inversion)
- **Location:** CollateralVault.pokeSettle (CollateralVault.sol:370)
- **Code smells:** single commingled freedHollar bucket per vault; deleverTarget consumed strictly before the FIFO queue loop
- **Note:** SubLoop.pullFreed returns the entire per-vault freedHollar, pooling equity freed from both queued-redemption slices and non-queued rebalance-down/adminUnwind unwinds. pokeSettle consumes availableHollar against deleverTarget (line 370) before the queue loop (line 387), so a redeemer's own freed slice can be diverted to de-lever/admin debt first; under a sustained decline with repeated permissionless rebalance() raising deleverTarget, redeemers can be delayed for the duration of the decline. Latency-only, self-resolving, no value lost (owed amounts snapshotted at request time), not profitably griefable, a fairness observation.

### adminUnwind + setYieldSource permanently strands still-freeable HOLLAR in the old source when the loop retains other vaults' aPRIME
- **Location:** CollateralVault.setYieldSource (CollateralVault.sol:700)
- **Code smells:** top-of-function pullFreed sweep captures freed-so-far but not future frees; relative drain branch with no absolute cap
- **Note:** Distinct market-regime variant of the drain-guard smell: when the residual falls under the relative branch BUT real aPRIME still backs it in the shared loop (other vaults keep aPRIME non-empty), setYieldSource repoints while unwindRequested[vault] is still positive; subsequent permissionless pokeRepay keeps crediting freedHollar[vault] in the OLD loop, which the now-repointed vault never pullFreed()s. Up to max(1e18, migrationDrainRef/1000) HOLLAR stranded until governance re-points back. Admin-gated and recoverable. Frictionless mocks drive residual to sub-1e18 dust so the relative branch is never the deciding condition.

### Negative-carry redemptions cannot fully settle; tail requests stay active, pinning totalQueuedDebt and under-sizing adminUnwind's deleverTarget
- **Location:** CollateralVault.pokeSettle (CollateralVault.sol:417)
- **Code smells:** head-advance test if(r.repaid >= r.debtShare) unreachable when freed equity < snapshot debtShare; no keeper top-up path
- **Note:** debtShare is snapshotted from live Main HOLLAR debt at requestRedeem (line 333); under negative carry the loop's freed equity is below seed, so total freed HOLLAR < total snapshot debtShare and r.repaid can never reach r.debtShare for the under-funded tail, leaving the request active and its residual pinned in totalQueuedDebt forever, under-sizing adminUnwind's deleverTarget = debt - totalQueuedDebt (line 669). Inherent async valuation-vs-realized economics (redeemers bear loop P&L; collateral released proportionally), self-corrects if carry recovers, not an exploit. Also independently refutes the self-flagged totalQueuedDebt underflow: repayNow <= remainingDebt so the counter is monotone >= 0.

### pokeBorrow lacks an unwind/de-lever inhibit; permissionless re-lever churns dust slippage during an active wind-down
- **Location:** SubLoop.pokeBorrow (SubLoop.sol:270)
- **Code smells:** no unwindTargetEquity/deleverDebtTarget guard, unlike pokeRepay (line 352)
- **Note:** pokeBorrow has no unwind/de-lever guard, but the extraction and DoS claims are refuted: it pays the caller nothing (only gas); deLever only sets a target at HF<=deLeverTrigger<targetHf, at which point pokeBorrow computes maxDebt8<=debtBase8 and returns 0 (no-op, cannot fight a de-lever); pokeRepay sizes its sell off STEP_HF_FLOOR=1.02 which is below pokeBorrow's deployHfFloor=1.05, so re-levering never reduces pokeRepay's headroom and equity is conserved, so queued redeemers still get their full unwindTargetEquity. Residual: during an unwind, round-tripping the appreciated HF>1.05 sliver bleeds ~2x dcaSlippagePpm, bounded non-compounding dust. Optional hardening (early-return when unwindTargetEquity>0 || deleverDebtTarget>0).

### AaveOracle reads have no zero-price/staleness guard; HOLLAR price of 0 collapses router min-out to 0
- **Location:** SubLoop._fundDeploy / _oracleRate (SubLoop.sol:317, 324-328)
- **Code smells:** getAssetPrice consumed with no !=0 / freshness assertion; numerator-zero silently disarms slippage protection while denominator-zero fail-closes
- **Note:** _fundDeploy computes fairOut = amount*pHollar/pPrime/1e12 and minOut = fairOut*(1e6-ppm)/1e6; if pHollar==0 then minOut==0 and the permissionless HOLLAR->aPRIME routerSell executes with a zero floor. Asymmetric: pPrime==0 reverts on division (fail-closed) but pHollar==0 silently disarms. Gated because reaching pHollar==0 requires an oracle mis-config/feed-failure no unprivileged actor controls for a configured $1 reserve, a missing defensive guard rather than a forced sandwich. Add pHollar!=0 && pPrime!=0 (and freshness) asserts in _oracleRate.

### Incremental deposits size borrow at exactly maxLTV of the collateral delta; accrued HOLLAR interest can brick further deposits with Aave error 36
- **Location:** CollateralVault.deposit (CollateralVault.sol:289)
- **Code smells:** borrow sized off (collAfter8-collBefore8)*maxLtv exactly; synthetic reserve LTV 0 adds no borrow power; no availableBorrowsBase haircut
- **Note:** Line 289 sizes borrowHollar at exactly maxLTV of the just-supplied collateral delta; after the first deposit account debt == ethColl*maxLtv leaving available borrows == 0, and a later deposit requires accrued_interest <= 0, so once variable-debt HOLLAR interest exceeds the 8dp base-currency truncation floor validateBorrow reverts with error 36 (COLLATERAL_CANNOT_COVER_NEW_BORROW). Fail-closed liveness only (vault becomes un-depositable, no theft); conditional on the HOLLAR reserve carrying a nonzero borrow rate (a 0% GHO-style mint would never tip over); pre-existing (only subLoop->yieldSource rename in the diff). MockPool accrues no interest so tests miss it. Size the borrow a hair below live availableBorrowsBase.

### Shared Harvester.harvest() reverts wholesale if a share-holding vault is paused by the guardian, blocking harvest for all healthy vaults
- **Location:** Harvester.harvest (Harvester.sol:68)
- **Code smells:** per-vault compound() is whenNotPaused (CollateralVault line 480) and invoked inside a shared loop with a strict require(registeredShares==total) at line 72
- **Note:** The headline adminUnwind-triggered DoS is REFUTED: adminUnwind zeroes the vault's loop shares (loopShares=0 at line 659, SubLoop.requestUnwind zeroes _sharesOf[vault]), so Harvester reads sharesOf(v)=0 => cut=0 => continue before ever calling compound; the require(registeredShares==total) stays consistent. Residual smell: a vault paused by the bare guardian pause() (line 723) WITHOUT adminUnwind still holds shares (sharesOf>0), so cut>0 and its whenNotPaused compound() reverts, reverting the entire shared harvest for all healthy vaults. Pre-existing, guardian/admin-privileged, liveness-only (resumes on unpause). Optional try/catch per-vault or exclude paused vaults from distribution.

