# HDCLVault Smart Contract Audit

**Date:** 2026-05-20
**Scope:** `src/HDCLVault.sol`, `src/libraries/QueueLib.sol`, `src/WDCLOracle.sol`
**Commit:** `2779338` (branch `feat/hdcl-vault`)
**Test suite:** 350 / 350 passing · 100% function coverage · 97% line coverage · 15 stateful invariants × 12,800 fuzz calls

This document supersedes the prior snapshot at `d2da6ae` (2026-03-13). Section [Resolved from prior audit](#resolved-from-prior-audit) reconciles each of the earlier findings with their current status; section [Open findings](#open-findings) lists what's still outstanding after Phase 1, Phase 2 (library split), the cancel-spam claim-DoS fix, and the spec-conformance pass (#4 / #13 / #17).

---

## Architecture Summary

An upgradeable (UUPS) ERC-20 vault that wraps Decentral Protocol NFT lending positions. ERC-4626 on the deposit side, ERC-7540 (async-redeem) on the withdraw side. Supports a registry of Decentral pools — new deposits route to one `activeDepositPool`, while each existing position is anchored to its origin pool via `positionPool[positionIndex]` so admin-driven rotation doesn't disturb live positions.

**Subsystems:**
- `HDCLVault` (≈1700 SLOC): token + accounting + position lifecycle + redemption queue + admin
- `QueueLib` (≈250 SLOC): redemption-queue mechanics extracted to keep the vault under EIP-170; library functions are `public` so they DELEGATECALL from a separately-deployed contract
- `WDCLOracle` (≈100 SLOC): Chainlink-compatible feed reading `vault.exchangeRate()` live

**Trust model:**
- `ADMIN_ROLE` — Hydration governance economics-parameters track (slow). Configures pools, oracle, TVL cap, min-amounts.
- `GUARDIAN_ROLE` — Hydration technical committee (fast). Pause/unpause only — superset of admin on pause; subset everywhere else.
- `UPGRADER_ROLE` — UUPS upgrade authority. Instant, no on-chain timelock.
- `CLAIM_OPERATOR_ROLE` — Keeper bot(s). Can call `redeem`/`withdraw` on behalf of users who opted into `setAutoClaim(true)`, constrained to `receiver == controller`.

No admin path to extract HOLLAR or NFTs from the vault. UUPS upgrade is the only "full-power" lever.

---

## Findings — current state

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| F-01 | LOW (defensive) | `_registerPool` does not check for duplicate `poolToken` | OPEN |
| F-02 | MEDIUM | `setMinReinvestAmount` accepts 0 — bricks `pokeQueue` no-progress cycles | OPEN |
| F-03 | LOW | `setOracle` install probe weaker than `getOraclePrice` read | OPEN |
| F-04 | INFO | `cancelRedeem` lacks `whenNotPaused` (intentional, undocumented) | OPEN |
| F-05 | LOW | Silent try/catch arms in `pokeDecentral` emit no event | OPEN |
| F-06 | MEDIUM | `pokeDecentral` yield-claim arm doesn't settle queue | OPEN |
| F-07 | LOW | Zero-asset `Withdraw` event from rounding dust on multi-partial claims | OPEN |
| F-08 | MEDIUM | `_depositIntoDecentral` trusts `amount` without balance-delta | OPEN |
| F-09 | LOW | Residual approval to Decentral pool between deposits | OPEN |
| F-10 | MEDIUM | `WDCLOracle.roundId = uint80(block.number)` — `answeredInRound >= roundId` guard is inert | OPEN |
| F-11 | LOW | `WDCLOracle.getRoundData` ignores `_roundId` (documented) | OPEN |
| F-12 | LOW | `WDCLOracle._scaledAnswer` reverts when rate < 1e10 (intentional) | OPEN |
| F-13 | LOW | `getEstimatedWaitTime` unbounded loops (view-only) | OPEN |
| F-14 | INFO | Operator-controller redirect at request time (per ERC-7540) | OPEN |
| F-15 | INFO | `DEAD_SHARES = 1000` small relative to industry norm; donation-resistant by accounting | OPEN |
| F-16 | INFO | Rate-lock at processing time, not request time (by design) | OPEN |

Sixteen findings, none CRITICAL or HIGH. Three MEDIUM, the rest LOW / INFO. None of the open items are exploitable for theft or fund-extraction in the current code.

---

## Open findings

### F-01 — `_registerPool` does not check for duplicate `poolToken` &nbsp; · LOW

**Location:** `HDCLVault.sol:1396-1409` (`_registerPool`)

**Description:** `_registerPool` validates `isPoolRegistered[newPool]` and `pool.stablecoin() == hollar` but does not check `isRegisteredPoolToken[poolTokenAddr]`. If admin registers two Decentral pools sharing the same `PoolToken` ERC-721 contract, retiring one calls `isRegisteredPoolToken[address(pool.poolToken())] = false` (line 1371) which breaks `onERC721Received` for every deposit/reinvest into the survivor — bricks the second pool until admin re-registers.

**Severity:** LOW — Decentral's factory pattern today gives every pool its own `PoolToken` contract, so the precondition isn't currently reachable. Defensive only.

**Fix:** Add `if (isRegisteredPoolToken[poolTokenAddr]) revert PoolAlreadyRegistered()` in `_registerPool` after the existing checks. One line.

---

### F-02 — `setMinReinvestAmount(0)` bricks `pokeQueue` no-progress path &nbsp; · MEDIUM

**Location:** `HDCLVault.sol:1283` (compare `setMinRedeemAmount`)

**Description:** `setMinRedeemAmount` enforces `if (amount == 0) revert MinMustBePositive()`. The parallel `setMinReinvestAmount` does not. With `minReinvestAmount = 0`, `pokeQueue`'s gate `idleHollar >= minReinvestAmount` is trivially true, so `_reinvest()` is called whenever the queue made no progress and deposits aren't paused. Inside `_reinvest`, the early-return `if (amount < minReinvestAmount) return` does not fire (always false for `amount >= 0`), so the call falls through to `pool.deposit(amount)`. If `amount` is below the Decentral pool's `minimumInvestmentAmount` (typically 10 HOLLAR), Decentral reverts and the revert propagates out of `pokeQueue` — bricking the permissionless settlement path until admin sets a non-zero min.

**Severity:** MEDIUM — admin-triggered, but a fat-finger that fully disables the keeper's main entrypoint.

**Fix:** Add `if (amount == 0) revert MinMustBePositive()` to `setMinReinvestAmount`. One line.

---

### F-03 — `setOracle` install probe weaker than read-time check &nbsp; · LOW

**Location:** `HDCLVault.sol:1315-1327` (compare `getOraclePrice` at 1262-1273)

**Description:** `setOracle` validates `answer > 0`, `updatedAt > 0`, `decimals ∈ [6,18]`. The read-time check `getOraclePrice` additionally validates `roundId != 0` and `answeredInRound >= roundId`. An admin can install an oracle that passes setup but reverts on every production read.

**Severity:** LOW — admin-only configuration error; catches at next read, not silently corrupted.

**Fix:** Add the same `if (roundId == 0) revert OracleRoundIncomplete()` and `if (answeredInRound < roundId) revert OracleStaleRound()` checks in `setOracle`. Two lines.

---

### F-04 — `cancelRedeem` lacks `whenNotPaused` &nbsp; · INFO

**Location:** `HDCLVault.sol:562`

**Description:** Every other state-mutating user entrypoint (`deposit`, `mint`, `requestRedeem`, `redeem`, `withdraw`, `pokeQueue`, `pokeDecentral`) carries `whenNotPaused`. `cancelRedeem` does not. During an emergency pause, users can still extract escrowed hDCL via cancel.

**Severity:** INFO — most likely intentional escape hatch ("pause stops new commitments, lets users back out"), but undocumented.

**Fix:** Add a natspec line: "Deliberately not gated by `whenNotPaused` — pause is an emergency state that should not trap user funds in the escrow. The settled portion remains rate-locked and must be claimed via `redeem`/`withdraw`." Doc-only.

---

### F-05 — Silent try/catch in `pokeDecentral` &nbsp; · LOW

**Location:** `HDCLVault.sol:708-738`, `744-766`, `771-781`, `787-829`

**Description:** Each of the four `pokeDecentral` state transitions wraps the Decentral call in a try/catch that returns silently on revert. Positions stuck in any intermediate state (e.g. Decentral paused, approval delayed, principal-withdrawal-delay not elapsed) continue counting toward `totalInvestedPrincipal` / `totalPendingYield` with no on-chain signal. Operators must rely on off-chain monitoring (the keeper at `keeper/src/keeper.ts` logs each failed attempt locally).

**Severity:** LOW — observability concern, not security. Amplifies operator dependency.

**Fix:** Emit `event PositionStuck(uint256 indexed positionIndex, uint8 state, bytes reason)` from each catch arm. Adds ~4 events × ~30B each to the contract; budget for size with current ~36 B EIP-170 buffer is tight, may need to compensate via inlined inline-getter cuts.

---

### F-06 — `pokeDecentral` yield-claim arm doesn't settle queue &nbsp; · MEDIUM

**Location:** `HDCLVault.sol:741-767`

**Description:** The YieldClaimed transition (`pool.executeYieldWithdrawal` succeeded) credits `idleHollar += yieldReceived` but does not call `_processQueueWithHollar`. Only the principal-redemption arm (line 823-826) does. Yield-only inflows that should immediately settle queued redeemers have to wait for the next `pokeQueue` call.

**Severity:** MEDIUM — delays claim availability in a routine cycle; not exploitable.

**Fix:** Copy the `if (totalQueuedHdcl > 0 && idleHollar > 0)` block from line 822-826 into the YieldClaimed arm right after `idleHollar += yieldReceived`. Four lines.

---

### F-07 — Zero-asset `Withdraw` event from rounding dust &nbsp; · LOW

**Location:** `QueueLib._claimByShares` / `_claimByAssets` (`QueueLib.sol:178`, `220`)

**Description:** `hollarTake = (take * r.hollarOwed) / r.hdclSettled` can truncate to zero when `take` is small relative to `r.hdclSettled` after partial fills. The vault burns shares for 0 HOLLAR; the `Withdraw` event fires with `assets = 0`. Cumulative accounting stays correct (the dust recovers on a future claim once a non-zero ratio fires), but per-call integrators see a "succeeded with 0 HOLLAR" signal.

**Severity:** LOW — cosmetic for integrators; no fund impact.

**Fix:** Either (a) skip pushes where `hollarTake == 0` and don't decrement `r.hdclSettled` for that step, or (b) document the dust behavior in the `redeem` natspec. (a) is cleaner but adds bytecode; (b) is doc-only.

---

### F-08 — Deposit-side principal trust without balance-delta &nbsp; · MEDIUM

**Location:** `HDCLVault.sol:469-498` (`_depositIntoDecentral`)

**Description:** `pool.deposit(amount)` is followed by `positions.push({ principal: amount, ... })` and `totalInvestedPrincipal += amount`, but the deposit side never measures `hollar.balanceOf(this)` before/after to verify Decentral actually consumed exactly `amount`. The withdraw side does (lines 745, 788). If a future Decentral version introduces a deposit fee or accepts partial fills, `totalInvestedPrincipal` overstates → `totalAssets()` overstates → exchange rate inflated until the position exits, at which point `PrincipalMismatch` surfaces the drift and it's socialized through the rate.

**Severity:** MEDIUM — defensive miss against future pool versions. Current Decentral takes exactly `amount`, so unreachable today.

**Fix:** Mirror the withdraw-side pattern:

```solidity
uint256 balBefore = hollar.balanceOf(address(this));
tokenId = pool.deposit(amount);
uint256 actualConsumed = balBefore - hollar.balanceOf(address(this));
// use actualConsumed in positions.push and totalInvestedPrincipal updates
```

---

### F-09 — Residual approval to Decentral pool &nbsp; · LOW

**Location:** `HDCLVault.sol:472-474`, `917-919`

**Description:** Both deposit paths do `safeApprove(pool, 0); safeApprove(pool, amount); pool.deposit(amount)` (the OpenZeppelin USDT-style zero-first pattern). Neither zeros the allowance after the deposit. If Decentral ever pulls less than `amount`, the residual sticks until the next deposit. Currently exploitable only if a registered pool is malicious — gated by admin registration.

**Severity:** LOW — defensive; admin trust boundary already covers the risk.

**Fix:** Add a trailing `hollar.safeApprove(address(pool), 0)` after each `pool.deposit(amount)`. Two one-liners.

---

### F-10 — Oracle roundId is `uint80(block.number)` &nbsp; · MEDIUM

**Location:** `WDCLOracle.sol:55-93`

**Description:** Both `latestRoundData` and `getRoundData` set `roundId = answeredInRound = uint80(block.number)`. Two consequences:

1. The vault's `getOraclePrice` enforces `answeredInRound >= roundId` (line 1269 of `HDCLVault.sol`). With both equal to `block.number`, this reduces to `block.number >= block.number` — **the staleness check is permanently inert**.
2. Block numbers aren't strictly monotonic across reorgs at the same height (different blocks at the same height share a number). Chainlink-pattern consumers that persist `lastRoundId` and reject `newRoundId <= storedRoundId` will silently freeze after a reorg.

**Severity:** MEDIUM — the inert guard isn't a vulnerability against the in-protocol oracle (it's always fresh by construction), but it becomes a real gap if admin rotates to a heartbeat-style external feed.

**Fix:** Use a monotonic counter incremented on each `latestRoundData` / `getRoundData` call, or use `uint80(block.timestamp)` (monotonic within the parachain). Storage-impact-aware: a counter needs a slot, which costs an SSTORE per oracle read. Time-derived id avoids the storage cost.

---

### F-11 — `WDCLOracle.getRoundData` ignores `_roundId` &nbsp; · LOW

**Location:** `WDCLOracle.sol:72-93`

**Description:** `_roundId` is unused; every field returned is current-state-shaped. Documented in natspec. Chainlink consumers indexing historical rounds (TWAP, fraud-proof, archival) receive present-time answers without an error signal.

**Severity:** LOW — Aave (the primary integration) uses `latestRoundData`, not `getRoundData`. Documented divergence.

**Fix:** If strict-historical consumers are anticipated, revert when `_roundId != uint80(block.number)`. Otherwise keep as-is; the natspec already warns integrators.

---

### F-12 — `WDCLOracle._scaledAnswer` reverts when rate < 1e10 &nbsp; · LOW

**Location:** `WDCLOracle.sol:101-105`

**Description:** Intentional: `require(scaled > 0, ...)` guards against truncating a non-zero 18-decimal rate to a zero 8-decimal Chainlink answer (which would cascade into mass liquidations downstream). The trade-off: after a catastrophic vault loss (rate < 1e-8 HOLLAR per hDCL), the oracle hard-reverts — Aave loses price access at exactly the moment liquidations should be possible.

**Severity:** LOW — known design trade-off; the failure mode is severe but the precondition (~99.999999% vault loss) requires a fundamental protocol break.

**Fix:** None recommended — accept as documented. Could be revisited if Aave adds a "stale oracle blocks borrows, allows liquidations" mode.

---

### F-13 — `getEstimatedWaitTime` unbounded loops &nbsp; · LOW

**Location:** `HDCLVault.sol:1080-1126`

**Description:** Two loops (`queueHead → requestId`, then `positionHead → positions.length`) with no per-call iteration cap. View-only — no on-chain caller can be griefed — but UI/indexer breakage on a long-lived deployment with thousands of queue entries or positions. Amplified by the cancel-spam path that was mitigated for *claim* in `0a3618c` but still bloats `queueTail` for view consumers.

**Severity:** LOW — view-only.

**Fix:** Cap iterations and return a sentinel (`type(uint256).max`) on overflow, with a companion `bool fullyEstimated` return to signal the truncation.

---

### F-14 — Operator-controller redirect at request time &nbsp; · INFO

**Location:** `HDCLVault.sol:494-528` (`requestRedeem`)

**Description:** An operator approved via `setOperator(operator, true)` can call `requestRedeem(shares, controller=<any>, owner)`. Funds come out of `owner`, but `request.user = controller` — all future `cancelRedeem` and `redeem`/`withdraw` authorize against `controller`, not `owner`. Per ERC-7540 this is allowed (the operator pattern is defined to permit redirect), but the `setOperator` natspec only emphasizes claim-time redirect — request-time controller assignment isn't called out.

**Severity:** INFO — per spec, not a bug. Documentation gap.

**Fix:** Extend the `setOperator` natspec to explicitly call out the request-time redirect behavior: "an approved operator can also pick the controller at `requestRedeem` time — funds come from `owner`, but `controller` becomes the canonical claim/cancel authority for the resulting request."

---

### F-15 — `DEAD_SHARES = 1000` small &nbsp; · INFO

**Location:** `HDCLVault.sol:42`

**Description:** Industry norm for inflation-attack mitigation is `1e6` shares dead-burned. The canonical donate-to-vault inflation vector is currently neutralized because `totalAssets()` reads from internal accounting (`totalInvestedPrincipal + accruedYield + idleHollar + totalPendingYield + totalReservedHollar`) rather than `hollar.balanceOf(this)` — so direct donations don't move the rate. But any future helper that sweeps balance into accounting reopens the attack at very low burn cost (1000 wei = 1e-15 HOLLAR per share).

**Severity:** INFO — currently safe, defensive note.

**Fix:** Bump to `1e6` if a future change touches accounting; not urgent.

---

### F-16 — Rate-lock at processing time, not request time &nbsp; · INFO

**Location:** `HDCLVault._processQueueWithHollar` / `pokeQueue`

**Description:** Redemption rate is snapshotted in `pokeQueue` (permissionless) when settlement happens, not at `requestRedeem` time. A redeemer holding a fresh queue entry can wait for a yield/principal event to land via permissionless `pokeDecentral`, then immediately call `pokeQueue` to lock the post-event rate before any other settlement. The mechanic exists by construction; not atomic (requires two separate txs the keeper would normally combine), but a sophisticated MEV searcher could submit them bundled.

**Severity:** INFO — by design. The catastrophic-rate guard (`if (hollarValue == 0) break;` in `QueueLib.processQueue`) handles the extreme case. FIFO ordering means the first redeemer in queue gets first claim on each settlement batch, so timing extraction is bounded by being head-of-queue.

**Fix:** None — adding a rate-floor at `requestRedeem` time would re-introduce the slippage parameter we deliberately removed in `0b74b8c`. The current behavior is the lesser evil.

---

## Resolved from prior audit

The prior audit at `d2da6ae` (2026-03-13) listed 18 findings. Below is the reconciliation against the current code at `2779338`:

| Prior # | Title | Resolution |
|---------|-------|------------|
| 1 | Exchange-rate drift during deposit queue processing | **RESOLVED** — pull-redemption refactor (`eb8bec4`): queue settlement is no longer triggered by `deposit`; it happens via permissionless `pokeQueue`. Rate is snapshotted once per batch in `_processQueueWithHollar`. |
| 2 | TVL cap excludes `totalStaleValue` | **RESOLVED** — stale machinery (`markPositionStale` / `totalStaleValue`) was removed entirely in the `47b7041` cleanup. TVL cap now correctly uses `totalAssets()` which sums all components. |
| 3 | Unbounded loop in `totalAssets()` (`activeAPYs` growth) | **RESOLVED** — Tier-2 bucket-abstraction removal removed `apyBuckets` / `activeAPYList`. `totalAssets` is now O(1) via `yieldRateSum` / `yieldOffsetSum` aggregates. |
| 4 | `DEAD_SHARES = 1000` weak | **OPEN as F-15** — documented as INFO; donation-resistant by accounting model. |
| 5 | `processPosition` bypasses Decentral withdrawal delay | **RESOLVED** — the sequential-if state machine is unchanged, but the Decentral pool's `principalWithdrawalDelaySeconds` is enforced inside `pool.executePrincipalWithdrawal` itself (try/catch at line 787 will revert if the delay hasn't elapsed). Vault cannot bypass. |
| 6 | `reinvest()` missing `whenNotPaused` | **RESOLVED** — `_reinvest` is internal-only and called from `pokeQueue` which has `whenNotPaused`. There's also a `!depositsPaused` gate at line 853. |
| 7 | Oracle `decimals()` missing | **RESOLVED** — `WDCLOracle.decimals()` exists at line 33 (returns 8). |
| 8 | No slippage on deposit | **RESOLVED** — intentionally removed in `0b74b8c`. Rate-lock + internal-accounting `totalAssets` makes deposit MEV-irrelevant. |
| 9 | Queue griefing | **RESOLVED** — cancel-spam claim-DoS fixed in `0a3618c` (per-controller `_settledByController` index). Iteration caps in `_processQueueWithHollar` (`MAX_QUEUE_ITERATIONS=50`, `MAX_QUEUE_SKIPS=500`). Cancel head-sweep capped at 50. Position head-sweep capped at 50 (`MAX_POSITION_HEAD_SWEEP`). |
| 10 | `cancelRedeem` doesn't advance `queueHead` | **RESOLVED** — added in `7b34c01`: `cancelRedeem` runs a bounded head sweep when cancelling at the head. |
| 11 | Fragile dual-tracking of HOLLAR in `deposit()` | **RESOLVED** — refactored into `_validateAndPreviewShares` + `_depositIntoDecentral`. Single source of truth on `idleHollar`. |
| 12 | No zero-address checks in `initialize()` | **RESOLVED** — all four addresses validated via `ZeroAddress` custom error (Phase 1 cleanup). |
| 13 | `setMinReinvestAmount(0)` allowed | **OPEN as F-02** — still missing the zero-guard. Asymmetric with `setMinRedeemAmount`. |
| 14 | No event on `initialize()` | **OPEN** — minor; `Deposited` / `OracleUpdated` etc. fire on first admin actions. Not re-elevated. |
| 15 | `positions` unbounded | **PARTIALLY RESOLVED** — `_advancePositionHead` is now bounded (F-13 fix opens this for further consideration). View-side iteration in `getEstimatedWaitTime` still unbounded (open as F-13). |
| 16 | `getRoundData` ignores `_roundId` | **OPEN as F-11** — documented in natspec; downgraded from a finding to a documented design choice. |
| 17 | Missing storage gap | **RESOLVED** — `__gap[49]` declared (one slot consumed by `_settledByController` in `0a3618c`). |
| 18 | `type(uint256).max` approval in `initialize()` | **RESOLVED** — replaced with per-call `safeApprove(pool, amount)` pattern in `_depositIntoDecentral` / `_reinvest`. |

---

## Recommendations Summary

Ordered by leverage:

| Priority | # | Action | Effort |
|----------|---|--------|--------|
| 1 | F-02 | Add zero-guard to `setMinReinvestAmount` | 1 line |
| 2 | F-06 | Settle queue in `pokeDecentral` yield-claim arm | 4 lines |
| 3 | F-01 | Reject duplicate `poolToken` in `_registerPool` | 1 line |
| 4 | F-03 | Match read-time checks in `setOracle` | 2 lines |
| 5 | F-04 | Natspec note on `cancelRedeem` pause-bypass intent | doc-only |
| 6 | F-10 | Switch `WDCLOracle.roundId` to monotonic counter or timestamp-derived | ~10 lines |
| 7 | F-08 | Balance-delta on `_depositIntoDecentral` | ~10 lines |
| 8 | F-05 | `PositionStuck` events on each `pokeDecentral` catch arm | ~8 lines |
| 9 | F-09 | Trailing `safeApprove(pool, 0)` after each deposit | 2 lines |
| 10 | F-13 | Cap loops in `getEstimatedWaitTime` + truncation flag | ~15 lines |
| 11 | F-14, F-04 | Doc-only natspec extensions | doc-only |

Items 1-5 cluster cleanly into a single ~30-minute commit (≈30 lines total). Items 6-10 are separate concerns, each ~1-2 hours including tests. F-11, F-12, F-15, F-16 are documented design choices — no code change recommended.

The vault is currently at 24,540 bytes deployed (36-byte buffer under EIP-170 at `optimizer_runs=30`). Some of the recommended fixes will push past that — Phase 3 `ViewLib` extraction (staged in `PLAN-library-split.md`) is the back-stop if it becomes necessary.

---

## Test posture

- 350 / 350 tests passing
- 100% function coverage on all in-scope contracts
- 97.12% line coverage on `HDCLVault.sol`
- 93.88% line coverage on `QueueLib.sol`
- 100% line coverage on `WDCLOracle.sol`
- 15 stateful fuzz invariants × 256 runs × 50 calls = 192,000 invariant checks per CI run
- Cancel-spam regression tests demonstrate claim-gas is bounded by user's own activity (21,674 gas at 10 cycles vs 21,694 at 1000 cycles)
- Heterogeneous-APY multi-pool tests cover 18% / 22% / 16% (incl. rate-cut scenario)
- E2E test against deployed lark testnet vault: 32 / 32 assertions passing

The remaining open findings are characteristically defensive misses, observability gaps, and ERC-7540 documentation extensions — not fund-extraction vectors. The "trivial cluster" (F-01, F-02, F-03, F-04, F-05) plus F-06 should be the next batch.
