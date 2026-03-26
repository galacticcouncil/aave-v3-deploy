# X-Ray Report

> HDCL Vault (Hydrated Decentral) | 677 nSLOC | a4f73f9 (`feat/hdcl-vault`) | Foundry | 26/03/26
> Spec: `.claude/HDCL-vault-specification.md` v0.1 (2026-03-10)

---

## 1. Protocol Overview

**What it does:** A fungible ERC-20 yield-bearing wrapper around Decentral Protocol's fixed-rate NFT lending positions, converting illiquid time-locked NFTs into a single liquid HDCL token (per spec §1).

- **Users**: Depositors provide HOLLAR stablecoin and receive HDCL tokens; redeemers queue HDCL for async conversion back to HOLLAR
- **Core flow**: Deposit HOLLAR → vault deposits into Decentral → receives NFT position → mints HDCL at current exchange rate → yield accrues → exchange rate appreciates (per spec §2)
- **Key mechanism**: Non-rebasing exchange rate model (per spec: "like Bifrost's vDOT"). `totalAssets()` computed in O(1) via aggregated accumulators `yieldRateSum`/`yieldOffsetSum`. Decentral uses simple interest, same formula mirrored in vault (per spec §4.3)
- **Token model**: HDCL is the vault share token (ERC-20, 18 decimals matching HOLLAR). HOLLAR is the underlying stablecoin. Decentral positions are NFTs held by the vault (per spec §3)
- **Admin model**: Single `ADMIN_ROLE` (per spec: "governance EOA managed through Hydration governance") controls all configuration. Separate `UPGRADER_ROLE` for UUPS upgrades. All admin actions instant — no timelock or multisig enforced on-chain. (Per spec §4.8): "There is no admin function to withdraw vault funds or NFTs. The only way HOLLAR leaves the vault is through the redemption queue or reinvestment into Decentral."

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault Core | HDCLVault.sol | 621 | ERC-20 token + vault logic + deposit/redeem/queue processing + position lifecycle |
| Oracle | WDCLOracle.sol | 56 | Chainlink-compatible price feed exposing HDCL exchange rate for external consumers |

### Spec Deviations

The following are differences between the spec (v0.1, 2026-03-10) and the current code at `a4f73f9`. These represent design decisions made post-spec — auditors should verify each is intentional.

1. **Oracle split into separate contract** — Spec §4.1 says vault inherits `AggregatorV3Interface`. Code splits oracle into standalone `WDCLOracle` contract. This resolves the `decimals()` conflict (ERC-20 returns 18, oracle needs 8) noted in the prior review. *Improvement over spec.*

2. **Function merges: `pokeDecentral` / `pokeQueue`** — Spec §4.5/§4.6/§4.7 defines three separate functions: `processPosition()`, `processQueue()`, `reinvest()`. Code merges these into `pokeDecentral(positionIndex)` and `pokeQueue()` (queue + reinvest). *Behavioral change — reinvest logic now runs when queue can't progress, not only when `totalQueuedHdcl == 0`.*

3. **`markPositionStale` has no withdrawal-delay guard** — Spec §4.5 requires position to be "stuck in a withdrawal-requested state for longer than `WITHDRAWAL_DELAY`". Code allows admin to mark ANY non-redeemed position stale. *Weaker guard than spec.*

4. **`totalAssets` includes `totalStaleValue`** — Spec §4.3: `totalAssets = totalInvestedPrincipal + accruedYield + idleHollar`. Code adds `+ totalStaleValue` to account for stale positions removed from active yield calculation. *New feature not in spec.*

5. **`setTvlCap` enforces `newCap >= totalAssets()`** — Spec §4.8: "Can be decreased (no forced withdrawals)". Code prevents setting cap below current totalAssets. *Stricter guard than spec — prevents cap from being meaningless.*

6. **Dynamic investment period** — Spec §4.1 hardcodes `INVESTMENT_PERIOD = 5,184,000`. Code reads from `decentralPool.minimumInvestmentPeriodSeconds()` dynamically. *More flexible.*

7. **`minRedeemAmount` added** — Not in spec. Code requires minimum 1 HDCL to request redemption, protecting from DoS via dust requests.

8. **`setOracle()` added** — Not in spec. Allows admin to change oracle address at any time.

9. **Queue uses mapping with head/tail** — Spec §4.6 uses array with `.active` field. Code uses `mapping(uint256 => RedemptionRequest)` with `queueHead`/`queueTail` pattern. *Gas optimization.*

10. **`WithdrawalDelayed` event defined but never emitted** — Spec §4.8 says vault should emit this when positions are stuck > 96 hours. Event exists in code but no logic triggers it.

11. **TVL cap check in deposit includes `totalStaleValue`** — Spec §4.2: `totalInvestedPrincipal + idleHollar + hollarAmount <= tvlCap`. Code: `totalInvestedPrincipal + idleHollar + totalStaleValue + hollarAmount > tvlCap`. *Accounts for stale value in cap — tighter.*

### How It Fits Together

The core trick: The vault abstracts Decentral Protocol's fixed-rate NFT positions into a fungible token by tracking all positions' principal and APY in aggregate buckets, computing yield in O(1) via `yieldRateSum` and `yieldOffsetSum` (per spec §4.3: "This is exact, not an approximation, because Decentral uses simple interest").

### Deposit Flow

```
User
└─ HDCLVault.deposit(hollarAmount)
   ├─ Calculate hdclMinted at current exchangeRate
   ├─ hollar.safeTransferFrom(user → vault)
   ├─ _mint(user, hdclMinted)
   ├─ hollar.safeApprove(decentralPool, amount)
   ├─ DecentralPool.deposit(hollarAmount) → tokenId
   │  └─ PoolToken.mint(vault, ...) → NFT
   ├─ positions.push(new NFTPosition)
   └─ _addToBucket(apyWad, principal, timestamp)
```
*First deposit mints DEAD_SHARES (1000) to 0xdead to mitigate share inflation (per spec §4.2: "first deposit mints dead shares for inflation protection").*

### Position Lifecycle (pokeDecentral)

```
Anyone
└─ HDCLVault.pokeDecentral(positionIndex)
   ├─ Active → YieldWithdrawalRequested
   │  └─ DecentralPool.requestYieldWithdrawal(tokenId)
   ├─ YieldWithdrawalRequested → YieldClaimed
   │  ├─ DecentralPool.executeYieldWithdrawal(tokenId)  ◄── requires Decentral approval
   │  ├─ _adjustBucketOnYieldClaim(pos)
   │  └─ idleHollar += yieldReceived
   ├─ YieldClaimed → PrincipalWithdrawalRequested
   │  └─ DecentralPool.requestPrincipalWithdrawal(tokenId)
   └─ PrincipalWithdrawalRequested → Redeemed
      ├─ DecentralPool.executePrincipalWithdrawal(tokenId)  ◄── requires approval + 48h delay
      ├─ _adjustBucketOnPrincipalRedemption(pos)
      ├─ idleHollar += principalReceived
      └─ _processQueueWithHollar(idleHollar, rate)
```
*(Per spec §4.4): "Yield MUST be claimed before principal. If `executePrincipalWithdrawal()` is called without first claiming yield, the NFT is burned by Decentral and all accrued yield is permanently lost." — enforced by the state machine.*

### Redemption Queue (pokeQueue)

```
Anyone
└─ HDCLVault.pokeQueue()
   ├─ _processQueueWithHollar(idleHollar, rate)
   │  ├─ FIFO: iterate queueHead → queueTail (max 50)
   │  ├─ Full fulfillment: _burn(escrowedHdcl), hollar.safeTransfer(user)
   │  └─ Partial fulfillment: burn proportional HDCL, transfer proportional HOLLAR
   └─ If queue can't progress + idleHollar >= minReinvestAmount → _reinvest()
      ├─ DecentralPool.deposit(amount) → new position
      └─ _addToBucket(apyWad, amount, timestamp)
```
*(Per spec §4.6): HDCL escrowed but NOT burned at request time — "The exchange rate is unaffected by queueing. The user continues to earn yield proportionally while waiting."*

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator** with **Liquid Staking** characteristics

The vault follows the yield aggregator pattern (deposit underlying → receive share token → yield accrues → exchange rate increases) but without ERC-4626 compliance. The withdrawal queue and exchange-rate-based derivative token add liquid staking characteristics. (Per spec §1): designed for composability as Aave V3 collateral and stableswap pool token.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| User | Untrusted | Deposit HOLLAR, request/cancel redemptions, transfer HDCL. Escrowed HDCL held by vault during pending redemptions |
| Keeper Bot | Untrusted | Call `pokeDecentral()` and `pokeQueue()` — permissionless (per spec §5: "no special role needed"). Multiple keepers can run concurrently |
| ADMIN_ROLE | Trusted | All operational functions instant: pause/unpause, pauseDeposits/unpauseDeposits, setTvlCap, setMinReinvestAmount, setMinRedeemAmount, setOracle, markPositionStale/unmarkPositionStale. (Per spec §4.8): "No admin function to withdraw vault funds or NFTs" — extraction limited to indirect manipulation |
| UPGRADER_ROLE | Trusted | Authorize UUPS proxy upgrades — instant, no timelock. Can change all contract logic |
| DEFAULT_ADMIN_ROLE | Trusted | Grant/revoke ADMIN_ROLE and UPGRADER_ROLE |

**Adversary Ranking** (ordered by threat level):

1. **Compromised admin/upgrader** — Holds instant, unrestricted power to change oracle, mark positions stale, pause operations, or upgrade the entire contract. (Per spec §6.2): flash loans disabled on Hydration, so instant oracle manipulation through flash loans is not possible, but compromised admin key remains the top threat.
2. **Share inflation attacker (first depositor)** — Canonical vault attack. (Per spec §6.2): mitigated by "dead shares" on first deposit. Code implements DEAD_SHARES = 1000.
3. **Exchange rate manipulator** — Manipulates `totalAssets()` to inflate/deflate share price. (Per spec §6.2): "idleHollar is tracked as state variable, not derived from balanceOf(). Donated HOLLAR does not affect the exchange rate." (per code) — verified correct.
4. **Queue front-runner** — Exploits timing between exchange rate changes and queue processing. (Per spec §6.2): "Front-running processPosition() has no economic benefit" — but this doesn't address front-running queue processing at favorable rates.
5. **Decentral Pool failure** — (Per spec §7.1): "If Decentral shuts down permanently, all pending withdrawal requests should still be processable." If Decentral fails to approve within SLA, admin marks stale and pauses deposits.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

1. **Vault ↔ Decentral Pool**: The vault fully trusts DecentralPool. (Per spec §6.2): "Legal SLA guarantees 48-hour turnaround. Automatic deposit pause if delayed > 96 hours." Code does NOT implement automatic pause — it relies on keeper bot monitoring (spec deviation #10: `WithdrawalDelayed` event never emitted).

2. **Admin boundary**: ADMIN_ROLE controls oracle, TVL cap, stale marking, pause — all instant. (Per spec §4.8): "There is no admin function to withdraw vault funds or NFTs." Verified in code — no direct extraction path. However, `markPositionStale` manipulates `totalAssets()` and therefore exchange rate, and `setOracle` redirects external consumers.

3. **Upgrader boundary**: UPGRADER_ROLE can replace the entire implementation via UUPS. This is the highest-privilege action — full fund extraction possible through malicious upgrade. No timelock.

4. **Oracle boundary**: `setOracle` (not in spec — code addition) instantly changes the oracle address. WDCLOracle is consumed by external protocols (Aave V3 per spec §4.3). A malicious oracle change has external blast radius.

### Key Attack Surfaces

- **ADMIN_ROLE / UPGRADER_ROLE compromise** — All admin functions are instant with no timelock. `setOracle` (not in spec) can redirect the price feed. `markPositionStale` is less restricted than spec intended (no withdrawal-delay guard — spec deviation #3). UUPS upgrade can replace all logic. (Per spec §4.8): no direct fund withdrawal, but admin can manipulate exchange rate via stale marking and indirect fund redirection via oracle change.

- **Exchange rate manipulation via totalAssets()** — `totalAssets()` is computed from four components: `totalInvestedPrincipal`, accrued yield (`block.timestamp * yieldRateSum - yieldOffsetSum`) / (`SECONDS_PER_YEAR * WAD`), `idleHollar`, and `totalStaleValue`. (Per spec §4.3): "This is exact (not an approximation) because positions within each bucket share the same APY and Decentral uses simple interest." The O(1) formula involves large intermediate values — `block.timestamp * yieldRateSum` could overflow with very large principals and high APYs. Rounding in deposit (line 325) and queue processing (lines 871, 894) use inverse formulas — rounding direction may not be symmetric.

- **Redemption queue fairness and rate snapshot** — Queue processes at exchange rate at time of fulfillment, not request. (Per spec §4.6): "The escrowed HDCL remains part of totalSupply(). The exchange rate is unaffected by queueing. At fulfillment time, the HDCL is burned at the then-current rate, ensuring the user receives yield accrued during the wait period." This is intentional design, but a keeper can choose favorable timing for `pokeQueue()`. `MAX_QUEUE_ITERATIONS = 50` (not in spec) limits throughput.

- **Decentral Pool external dependency** — 100% of invested funds in one external pool. (Per spec §7.1): if Decentral pauses, "existing NFTs cannot be withdrawn until unpause" and "admin should call pauseDeposits() and markPositionStale()." The vault has no emergency withdrawal mechanism bypassing Decentral's approval flow. `try/catch` silently swallows errors.

- **Stale position accounting** — `markPositionStale` removes a position from active yield calculation and snapshots value into `totalStaleValue`. (Per spec §4.5): should only be callable when position is "stuck in a withdrawal-requested state for longer than WITHDRAWAL_DELAY" — code has NO such guard (spec deviation #3). Admin can mark ANY non-redeemed position stale, arbitrarily shifting value between active and stale accounting, manipulating exchange rate.

### Upgrade Architecture Concerns

- **No timelock on UUPS upgrades** — `_authorizeUpgrade` only requires `UPGRADER_ROLE` with no delay.
- **No storage gap** — `HDCLVault.sol` does not declare `uint256[N] private __gap`. Future upgrades adding parent contracts could cause storage collisions.
- **Implementation protection** — Constructor calls `_disableInitializers()` (good).

### Protocol-Type Concerns

**As a Yield Aggregator:**
- Share price at `totalSupply == 0` returns `WAD` (1:1). DEAD_SHARES (1000 wei to `0xdead`) prevents inflation attack (per spec §6.2). (Per spec §7.4): "Next depositor gets 1:1 rate. This is correct behavior."
- `totalAssets()` uses purely internal accounting — direct HOLLAR donations are NOT reflected. (Per spec §6.2): "idleHollar is tracked as state variable... Donated HOLLAR does not affect the exchange rate." This creates a permanent gap between real balance and tracked assets — (per spec §7.5): "This dust accumulates harmlessly in idleHollar."
- Not ERC-4626 compliant — custom async redemption model means standard vault integrations don't apply.

**As Liquid Staking:**
- Withdrawal queue creates illiquidity risk. (Per spec §1): "Users can exit via the redemption queue (max ~62 days) or instantly via secondary markets (stableswap pool)." The stableswap pool is out of scope but is the intended fast-exit path.
- `unmarkPositionStale` resets `yieldStartTime` to `block.timestamp`, erasing accrued yield for that position's contribution — correct behavior per spec intent (restart yield tracking after stale period).

### Temporal Risk Profile

**Deployment & Initialization:**
- `initialize()` uses `initializer` modifier — safe against re-initialization. Proxy deployment + initialize should be atomic. (Per spec §9): Phase 2 includes "Seed initial deposit to establish the 1:1 exchange rate and avoid first-depositor attack."
- (Per spec §9): All roles initially granted to single admin address — single-key risk window until role transfer.

**Market Stress:**
- (Per spec §7.3): "If all vault deposits were made at the same time, all NFTs mature on the same day... exchange rate growth temporarily flattens." With continuous deposits, positions naturally stagger.
- If Decentral Pool becomes illiquid, `markPositionStale` preserves `totalAssets()` accuracy but doesn't recover funds.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **DecentralPool** — via `HDCLVault:deposit`, `requestYieldWithdrawal`, `executeYieldWithdrawal`, `requestPrincipalWithdrawal`, `executePrincipalWithdrawal`
> - Assumes: Correct yield calculation based on `fixedAPYWad`, timely approval within 48h SLA (per spec §6.2), principal returned in full
> - Validates: NONE — vault uses `try/catch` on execute calls, does not validate returned amounts
> - Mutability: External contract, likely upgradeable (has UPGRADER_ROLE in interface)
> - On failure: `try/catch` silently returns — position stays in current state, retried next `pokeDecentral()` call

> **PoolToken (NFT)** — via `DecentralPool` (indirect — vault receives NFTs via `onERC721Received`)
> - Assumes: NFTs minted correctly on deposit, ownership tracked correctly
> - Validates: `onERC721Received` returns correct selector
> - Mutability: External contract
> - On failure: Deposit reverts if NFT mint fails

> **HOLLAR (Stablecoin)** — via `safeTransferFrom`, `safeTransfer`, `safeApprove`
> - Assumes: Standard ERC-20 behavior, no fee-on-transfer, no rebasing, no blacklisting (per spec: "HOLLAR: 18 decimals")
> - Validates: Uses SafeERC20 for all interactions
> - Mutability: Unknown — if upgradeable, behavior could change
> - On failure: SafeERC20 reverts on failed transfer

> **IAggregatorV3Interface (Oracle)** — via `HDCLVault.getOraclePrice()`, `WDCLOracle.latestRoundData()`
> - Assumes: Positive price answer, correct decimals
> - Validates: `require(answer > 0)` in getOraclePrice; no staleness check. (Per spec §6.2): "The oracle is calculated from block.timestamp, so it can never be stale — it updates every block"
> - Mutability: Oracle address changeable instantly by admin (`setOracle` — not in spec)
> - On failure: Reverts with "Invalid oracle price"

**Token Assumptions** (unvalidated):
- HOLLAR: assumes no fee-on-transfer — impact if violated: `idleHollar` tracker overstates actual balance, queue fulfillment transfers fail
- HOLLAR: assumes no rebasing — impact if violated: `totalAssets()` drifts from reality

---

## 3. Invariants

### Stated Invariants (per spec §6.3)

1. **Shares require backing**: `totalSupply() > 0 ⟹ totalAssets() > 0` — no way to have shares without backing
2. **Idle never over-counted**: `idleHollar <= hollar.balanceOf(address(this))` — never over-count idle
3. **Escrow sufficiency**: `totalQueuedHdcl <= balanceOf(address(vault))` — escrowed HDCL is in vault
4. **NFT ownership**: Every NFT in `positions[]` with state != Redeemed must be owned by vault in PoolToken
5. **Rate monotonicity**: `exchangeRate()` is monotonically non-decreasing under normal operation
6. **Yield-before-principal**: Yield always claimed before principal for every position — enforced by state machine

### Stated Invariants (per spec, elsewhere)

7. **No admin extraction** (per spec §4.8): "There is no admin function to withdraw vault funds or NFTs. The only way HOLLAR leaves the vault is through the redemption queue or reinvestment." (per code) — verified: no `withdraw` or `transferNFT` function exists.
8. **Donation resistance** (per spec §6.2): "idleHollar tracked as state variable, not derived from balanceOf(). Donated HOLLAR does not affect exchange rate." (per code) — verified: `totalAssets()` uses `idleHollar` not `balanceOf`.
9. **Queue rate neutrality** (per spec §4.6): "Burning HDCL at the exchange rate is proportionally neutral: (totalAssets - hollar) / (totalSupply - hdcl) = totalAssets / totalSupply". (per code) — rate calculated once per batch, so this holds within a single `_processQueueWithHollar` call.

### Inferred Invariants (per code)

- **Accounting identity**: `totalAssets() == totalInvestedPrincipal + accruedYield + idleHollar + totalStaleValue`. If violated: exchange rate incorrect, all deposits/redemptions use wrong price.
- **Bucket consistency**: `yieldRateSum == Σ(apyWad × principal)` and `yieldOffsetSum == Σ(apyWad × principal × yieldStartTime)` for all non-stale positions. If violated: accrued yield calculation returns wrong value.
- **Queue HDCL accounting**: `totalQueuedHdcl == Σ(hdclAmount - hdclFulfilled)` for active queue entries. If violated: queue processing under/over-distributes HOLLAR.
- **Position state monotonicity**: NFTState transitions only forward: Active → YWR → YC → PWR → Redeemed. If violated: positions could be double-processed.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing | No README in hdcl-vault/ |
| NatSpec | Present | Good coverage on public functions in HDCLVault.sol and WDCLOracle.sol |
| Spec/Whitepaper | Present | `.claude/HDCL-vault-specification.md` v0.1 (52KB, 1047 lines) — comprehensive spec covering architecture, flows, security, edge cases |
| Inline Comments | Adequate | Key sections have headers and brief inline comments |

Spec quality is high — includes worked examples (Appendix B), explicit invariants (§6.3), attack vector mitigations (§6.2), and edge case analysis (§7). 11 spec deviations identified (see §1 above) — auditors should verify each is intentional.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 8 (with test functions) | File scan |
| Test functions | 78 | File scan |
| Line coverage | 88.32% (HDCLVault), 100% (WDCLOracle) | forge coverage |
| Branch coverage | 64.15% (HDCLVault), 66.67% (WDCLOracle) | forge coverage |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 78 | HDCLVault (deposit, exchange rate, redemption queue, position processing, admin, reinvest, first depositor), WDCLOracle |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry) | 0 | none |
| Stateful Fuzz (Echidna) | 0 | none |
| Formal Verification (Certora) | 0 | none |

### Gaps

- **No fuzz testing**: Exchange rate math (`yieldRateSum`/`yieldOffsetSum` calculations) involves large intermediate products — high priority for stateless fuzz to find overflow/rounding edge cases.
- **No stateful/invariant testing**: Position lifecycle state machine (5 states) and redemption queue (partial fulfillment, cancellation, head advancement) need invariant testing. (Per spec §6.3): six explicit invariants exist but none are encoded as on-chain assertions or off-chain property tests.
- **No formal verification**: Core accounting invariants (bucket consistency, queue HDCL tracking, exchange rate monotonicity) are suitable for formal verification.
- **Branch coverage at 64%**: Significant untested branches — likely edge cases in queue processing, stale position handling, and TVL cap enforcement.

---

## 6. Developer & Git History

> Repo shape: normal development — Active development with 10 source-touching commits over 3 days on the `feat/hdcl-vault` branch. Git security analysis reported `squashed_import` due to path mismatch (monorepo subdirectory), but hotspot data and recent commits confirm active development.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| lolmcshizz | 1 | +1436 / -0 | 64% |
| Yash Sharma | 9 | +805 / -329 | 36% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors (source) | 2 | Small team |
| Merge commits | 75 of 366 (20%) | Formal review process exists in parent repo |
| Repo age | 2022-11-22 → 2026-03-26 | 3.3 years (parent repo); vault feature is ~3 days old |
| Recent source activity (30d) | 10 commits | Active — rapid development burst |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| HDCLVault.sol | 9 | Highest churn — prioritize review |
| WDCLOracle.sol | 2 | Stable after initial creation |
| IDecentralPool.sol | 2 | Interface evolution |
| IHDCLVault.sol | 2 | Interface evolution |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| f0c4eac | 2026-03-26 | zero-address checks, oracle pause revert, stale yield fix, TVL cap guard, reinvest cap fix | 10 | Explicit security + oracle/pricing |
| f2e2f10 | 2026-03-24 | Interface fixes, max hollar approval removed, processQueue removed from deposit | 8 | Explicit security language |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts | lib/openzeppelin-contracts | OpenZeppelin | Submodule | Standard |
| openzeppelin-contracts-upgradeable | lib/openzeppelin-contracts-upgradeable | OpenZeppelin | Submodule | Standard |

### Security Observations

- **Rapid development cycle**: 10 commits in ~3 days with significant logic changes. High velocity increases defect risk.
- **Two-contributor codebase**: Initial scaffold by lolmcshizz, all subsequent modifications by Yash Sharma. Single-developer modification pattern.
- **Security-scored commit f0c4eac (score 10)**: 5 distinct fixes bundled — found during review, not caught by tests.
- **Spec exists but code has diverged**: 11 deviations identified. Most are improvements, but #3 (markPositionStale without guard) and #10 (WithdrawalDelayed never emitted) are weaker than spec intent.
- **No fuzz or formal verification**: For a vault with complex O(1) yield math and 6 spec-stated invariants, the absence of property-based testing is a significant gap.

### Cross-Reference Synthesis

- **HDCLVault.sol** is both the highest-churn file (9 modifications) AND the sole contract with all attack surfaces — prioritize for deep review.
- Security commit f0c4eac fixes stale yield double-counting and TVL cap underflow — both relate to "Stale position accounting" and "Exchange rate manipulation" attack surfaces.
- Spec deviation #3 (`markPositionStale` without withdrawal-delay guard) directly weakens the "ADMIN_ROLE compromise" attack surface — admin has more power than spec intended.
- Branch coverage at 64% aligns with untested edge cases in queue processing and stale handling — the same areas with spec deviations.

---

## X-Ray Verdict

**FRAGILE** — Unit tests exist with good coverage (88% line) but no fuzz, invariant, or formal verification for a vault with non-trivial O(1) yield math, 6 spec-stated invariants, and async queue processing. All admin operations are instant with no on-chain timelock. Comprehensive spec exists but code has 11 deviations, including weaker-than-spec admin guards.

**Structural facts:**
1. 677 nSLOC across 2 in-scope contracts (HDCLVault + WDCLOracle), with HDCLVault comprising 92% of the codebase
2. 78 unit tests passing with 88% line / 64% branch coverage; 0 fuzz, 0 invariant, 0 formal verification — despite 6 explicit invariants in spec
3. UUPS upgradeable with no timelock — UPGRADER_ROLE can replace implementation instantly; no storage gap declared
4. 2 contributors to source; all 9 post-initial modifications by a single developer over 3 days
5. Comprehensive spec (1047 lines) with 11 identified code deviations — 2 weaken security posture vs spec intent (#3: stale guard, #10: delayed event)
