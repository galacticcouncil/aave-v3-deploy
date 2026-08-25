# 🔐 Security Review — hdcl-vault

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (all `.sol` outside excluded dirs)             |
| **Files reviewed**               | `src/HDCLVault.sol` · `src/WDCLOracle.sol`<br>`script/Deploy.s.sol` · `script/Upgrade.s.sol` |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[90] **1. Cancel-spam permanently bricks the claim path via unbounded loop from index 0**

`HDCLVault._claimByShares / _claimByAssets` · Confidence: 90

**Description**
`_claimByShares` (line 694) and `_claimByAssets` (line 727) iterate `for (uint256 i = 0; i < queueTail && remaining > 0; i++)` with no per-call iteration cap, while `_processQueueWithHollar` has `MAX_QUEUE_ITERATIONS = 50` and `MAX_QUEUE_SKIPS = 500`. `queueTail` is the all-time count of `requestRedeem` calls and is never decremented; deleted slots below `queueHead` still cost a cold SLOAD per iteration (~2100 gas for `r.user`). An attacker holding only `minRedeemAmount` (1 HDCL) can loop `requestRedeem(1e18, self, self)` → `cancelRedeem(id)` — each cycle costs ~150k gas, refunds the seed HDCL, and leaves one deleted slot in `[0, queueTail)`. ~7,000 cycles (≈$1–$10 of gas on a Hydration parachain at current rates) push the claim loop past a 30M-gas block ceiling, after which any user with settled HOLLAR (`hdclSettled > 0`) can never reach the redeem/withdraw side. Their escrowed hDCL is in `address(this)` and their reserved HOLLAR is in `totalReservedHollar` — both permanently inaccessible since `cancelRedeem` only refunds the *unsettled* portion.

**Fix**

```diff
- function _claimByShares(address controller, uint256 shares) internal returns (uint256 assets) {
-     uint256 remaining = shares;
-     for (uint256 i = 0; i < queueTail && remaining > 0; i++) {
-         Request storage r = redemptionQueue[i];
-         if (r.user != controller || r.hdclSettled == 0) continue;
-         /* ... */
-     }
- }
+ // Track each controller's settled-but-unclaimed request ids; populated in
+ // _processQueueWithHollar whenever hdclSettled transitions from 0 → >0 for
+ // the first time, removed when the entry is fully drained in this loop.
+ mapping(address => uint256[]) internal _settledByController;
+
+ function _claimByShares(address controller, uint256 shares) internal returns (uint256 assets) {
+     uint256 remaining = shares;
+     uint256[] storage ids = _settledByController[controller];
+     for (uint256 j = ids.length; j > 0 && remaining > 0; ) {
+         unchecked { --j; }
+         uint256 i = ids[j];
+         Request storage r = redemptionQueue[i];
+         if (r.user != controller || r.hdclSettled == 0) {
+             ids[j] = ids[ids.length - 1]; ids.pop();
+             continue;
+         }
+         /* ...existing partial/full drain logic... */
+         if (r.hdclSettled == 0) { ids[j] = ids[ids.length - 1]; ids.pop(); }
+     }
+ }
```

Apply the symmetric change to `_claimByAssets`. `_processQueueWithHollar` must push the request id into `_settledByController[r.user]` the first time `hdclSettled` becomes non-zero for that request. With iteration bounded by the controller's own outstanding settled entries, the queueTail-bloat path no longer affects per-user claim gas. No new external calls were introduced (no new reentrancy surface), no new DoS (per-user list is bounded by that user's own activity), and the existing `nonReentrant`/`whenNotPaused` guards remain in place.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Cancel-spam permanently bricks the claim path via unbounded loop from index 0 |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Phantom-yield window from maturity-cap mismatch** — `HDCLVault.pokeDecentral` — Code smells: `expected = (principal * apyWad * (block.timestamp - yieldStartTime)) / (year * WAD)` at line 782-785 is uncapped at maturity, while the parallel calculation in `getEstimatedWaitTime` (line 1174-1176) caps at `pos.maturityTime`. If Decentral truncates yield at maturity (typical for fixed-yield products), late `pokeDecentral` inflates `totalPendingYield` between request and execute; any `requestRedeem` + `pokeQueue` during this window rate-locks at the inflated rate, and the shortfall is socialized to non-redeemers. Unverified: whether Decentral actually caps at maturity.

- **retirePool clears a poolToken that may still belong to a live pool** — `HDCLVault.retirePool` — Code smells: line 1438 unconditionally sets `isRegisteredPoolToken[address(pool.poolToken())] = false` without checking whether any other registered pool shares the same NFT contract; `_registerPool` does not enforce poolToken uniqueness. If admin ever registers two pools sharing one poolToken (Decentral factory pattern, versioned proxy), retiring one bricks `onERC721Received` for the survivor — every subsequent deposit reverts with "Only pool NFTs" until admin re-registers.

- **Rate-lock-at-process timing extraction** — `HDCLVault._processQueueWithHollar / pokeQueue` — Code smells: redemption rate is locked at `pokeQueue` settlement (which is permissionless), not at request time. A redeemer holding a fresh queue entry can wait for a yield/principal event to land via permissionless `pokeDecentral`, then immediately call `pokeQueue` to lock the post-event rate before any other settlement. Vault has no rate floor/ceiling between request and lock; not atomic but the mechanic exists by construction.

- **previewDeposit returns 0 in catastrophic-state instead of reverting** — `HDCLVault.previewDeposit` — Code smells: returns 0 when `totalSupply() > 0 && totalAssets() == 0`, but `_validateAndPreviewShares` reverts in that state with "Vault has no assets". ERC-4626 §previewDeposit requires preview to match the actual call — an integrator polling preview can ship a transaction that unexpectedly reverts.

- **setOracle probe is weaker than the read-time check** — `HDCLVault.setOracle` — Code smells: install validates `answer > 0`, `updatedAt > 0`, `decimals ∈ [6,18]`, but omits the `answeredInRound >= roundId` and `roundId != 0` checks that `getOraclePrice` later enforces. Admin can wire an oracle that passes install but fails every production read.

- **WDCLOracle.getRoundData silently returns current data for any roundId** — `WDCLOracle.getRoundData` — Code smells: `_roundId` argument is ignored and every tuple field is current-state-shaped. Chainlink consumers indexing historical rounds (TWAP, fraud-proof) receive present-time answers without an error signal. Documented in natspec but the contract still inherits `IAggregatorV3Interface`.

- **cancelRedeem lacks whenNotPaused while every other user mutator enforces it** — `HDCLVault.cancelRedeem` — Code smells: every state-mutating user entrypoint (`deposit`, `mint`, `requestRedeem`, `redeem`, `withdraw`, `pokeQueue`, `pokeDecentral`) is gated by `whenNotPaused` — `cancelRedeem` is not, without a natspec note. Either deliberate escape hatch or accidental omission; during pause users can still extract escrowed HDCL.

- **setMinReinvestAmount accepts 0 while setMinRedeemAmount blocks it** — `HDCLVault.setMinReinvestAmount` — Code smells: `setMinRedeemAmount` enforces `require(amount > 0)` with a queue-grief rationale in natspec; the parallel setter has no such check. With `minReinvestAmount = 0`, `pokeQueue`'s tail branch (`idleHollar >= minReinvestAmount`) is always true and `_reinvest()` calls `pool.deposit(0)`, which the Decentral pool likely reverts on — DoSing `pokeQueue` whenever the queue makes no progress.

- **Residual approval to Decentral pool between deposits** — `HDCLVault._depositIntoDecentral / _reinvest` — Code smells: both call `safeApprove(pool, 0); safeApprove(pool, amount); pool.deposit(amount);` but never zero-out post-deposit. If the pool ever pulls less than `amount`, the residual allowance persists until the next deposit. Cross-deposit window is exploitable only if a registered pool is malicious; flagged because the pool registry supports multiple admin-vetted pools.

- **pokeDecentral does not settle the queue on yield-claim arms** — `HDCLVault.pokeDecentral` — Code smells: the `YieldWithdrawalRequested → YieldClaimed` arm (lines 808-833) credits `idleHollar += yieldReceived` but never calls `_processQueueWithHollar`. Only the principal-redemption arm does. Yield-only inflows must wait for the next `pokeQueue` even when sufficient HOLLAR sits idle to settle queued redeemers.

- **Silent try/catch on every pokeDecentral state transition hides wedged positions** — `HDCLVault.pokeDecentral` — Code smells: all four state-transition blocks wrap Decentral calls in `try/catch` that emit no event on revert. Positions stuck in any intermediate state continue to count toward `totalInvestedPrincipal` and `totalPendingYield` with no on-chain signal. Amplifies the maturity-cap-mismatch lead by extending the exposure window invisibly.

- **Zero-asset claim emits misleading Withdraw event** — `HDCLVault._claimByShares / _claimByAssets` — Code smells: `hollarTake = (take * r.hollarOwed) / r.hdclSettled` (and the symmetric `sharesTake` in `_claimByAssets`) can truncate to 0 when one side of the ratio collapses after partial fills. The user burns `take` shares for 0 HOLLAR (or vice versa); cumulative claim still reconciles but the `Withdraw` event carries `assets = 0` and integrators dispatching per-call may emit "claim succeeded with 0 HOLLAR" signals.

- **_advancePositionHead unbounded sweep can wedge pokeDecentral** — `HDCLVault._advancePositionHead` — Code smells: unbounded `while` (lines 1627-1634) advancing past consecutive `NFTState.Redeemed` positions. Positions can redeem out-of-order (multiple pools with different periods, manual operator sequencing). A large gap (e.g. positions[10..1000] redeemed before [0..9]) forces a multi-million-gas SLOAD sweep on the eventual head redemption.

- **Deposit-side principal trust without balance-delta** — `HDCLVault._depositIntoDecentral` — Code smells: `pool.deposit(amount)` is followed by `positions.push({ principal: amount, ... })` and `totalInvestedPrincipal += amount`, but `pokeDecentral` uses balance-delta on the withdraw side. If a registered pool ever consumes less than `amount` (deposit-side fee), `totalAssets` is overstated for the position's lifetime; surfaces only at `executePrincipalWithdrawal` (`PrincipalMismatch`) and is then socialized through the exchange rate.

- **WDCLOracle._scaledAnswer reverts when rate < 1e10** — `WDCLOracle._scaledAnswer` — Code smells: `require(scaled > 0)` reverts whenever `vault.exchangeRate() < 1e10`. After a catastrophic Decentral loss the vault rate could collapse far below `1e10`, cascading the oracle into a hard-revert state. Downstream lending markets quoting wDCL collateral would lose price access at exactly the wrong moment (blocking liquidations). Intentional per natspec but the failure mode is severe.

- **WDCLOracle uses uint80(block.number) as roundId** — `WDCLOracle.latestRoundData` — Code smells: `roundId = uint80(block.number)` is not strictly monotonic across reorgs; Chainlink-pattern consumers that persist last-seen roundId and reject `newRoundId <= storedRoundId` will silently freeze after a reorg. Same value used for `answeredInRound`, so the `answeredInRound >= roundId` guard in `HDCLVault.getOraclePrice` is permanently inert.

- **maxRedeem/maxWithdraw hardcoded to 0** — `HDCLVault.maxRedeem / maxWithdraw` — Code smells: returns 0 with comment "async-only". Per ERC-7540 the values should reflect the controller's claimable share/asset balance once a request transitions to Claimable, so 4626-aware integrators can size a `redeem` call. Documented divergence but still a usability/spec issue that can route users away from settled funds.

- **Operator-controller redirect at request time** — `HDCLVault.requestRedeem` — Code smells: an approved operator can call `requestRedeem(shares, controller=attacker, owner)` — vault `_transfer`s HDCL out of `owner` and assigns `request.user = controller`. Both cancel and claim then authorize against the new controller, not the original owner. ERC-7540 trust model permits this, but the `setOperator` natspec only emphasizes post-claim redirect, not request-time controller assignment.

- **getEstimatedWaitTime unbounded loops** — `HDCLVault.getEstimatedWaitTime` — Code smells: two loops (`queueHead → requestId`, `positionHead → positions.length`) with no iteration cap and per-position external calls. View-only — no on-chain caller — but UI/indexer breakage on a long-lived deployment, amplified by the cancel-spam path that drives the queue index large.

- **DEAD_SHARES = 1000 is small relative to standard inflation-attack mitigations** — `HDCLVault._validateAndPreviewShares` — Code smells: 1000 wei locked to `0xdead`. The canonical donate-to-vault inflation vector is currently neutralized because `idleHollar` updates from internal accounting rather than `balanceOf` reads, but any future helper that sweeps balance into accounting reopens the attack at very low burn cost.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
