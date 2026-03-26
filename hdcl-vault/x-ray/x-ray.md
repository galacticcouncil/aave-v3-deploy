# X-Ray Report

> HDCL Vault (Hydrated Decentral) | 677 nSLOC | a4f73f9 (`feat/hdcl-vault`) | Foundry | 26/03/26

---

## 1. Protocol Overview

**What it does:** A fungible ERC-20 yield-bearing wrapper around Decentral Protocol's fixed-rate NFT lending positions, converting illiquid time-locked NFTs into liquid HDCL tokens.

- **Users**: Depositors provide HOLLAR stablecoin and receive HDCL tokens; redeemers queue HDCL for async conversion back to HOLLAR
- **Core flow**: Deposit HOLLAR → vault deposits into Decentral Pool → receives NFT position → mints HDCL at current exchange rate → yield accrues → exchange rate appreciates
- **Key mechanism**: Non-rebasing share-token model. `totalAssets()` computed as `totalInvestedPrincipal + accruedYield + idleHollar + totalStaleValue`. Exchange rate = `totalAssets * WAD / totalSupply`
- **Token model**: HDCL is the vault share token (ERC-20). HOLLAR is the underlying stablecoin. Decentral positions are NFTs held by the vault
- **Admin model**: Single `ADMIN_ROLE` controls all configuration (TVL cap, oracle, pause, stale marking). Separate `UPGRADER_ROLE` for UUPS upgrades. All admin actions are instant — no timelock or multisig enforced on-chain

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault Core | HDCLVault.sol | 621 | ERC-20 token + vault logic + deposit/redeem/queue processing + position lifecycle |
| Oracle | WDCLOracle.sol | 56 | Chainlink-compatible price feed exposing HDCL exchange rate for external consumers |

### How It Fits Together

The core trick: The vault abstracts Decentral Protocol's fixed-rate NFT positions into a fungible token by tracking all positions' principal and APY in aggregate buckets, computing yield in O(1) via `yieldRateSum` and `yieldOffsetSum`.

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
*First deposit mints DEAD_SHARES (1000) to 0xdead to mitigate share inflation.*

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
      ├─ DecentralPool.executePrincipalWithdrawal(tokenId)  ◄── requires approval + delay
      ├─ _adjustBucketOnPrincipalRedemption(pos)
      ├─ idleHollar += principalReceived
      └─ _processQueueWithHollar(idleHollar, rate)
```
*Each `try` block silently returns on failure — positions retry on next call.*

### Redemption Queue (pokeQueue)

```
Anyone
└─ HDCLVault.pokeQueue()
   ├─ _processQueueWithHollar(idleHollar, rate)
   │  ├─ FIFO: iterate queueHead → queueTail (max 50)
   │  ├─ Full fulfillment: _burn(escrowedHdcl), hollar.safeTransfer(user)
   │  └─ Partial fulfillment: burn proportional HDCL, transfer proportional HOLLAR
   └─ If queue empty + idleHollar >= minReinvestAmount → _reinvest()
      ├─ DecentralPool.deposit(amount) → new position
      └─ _addToBucket(apyWad, amount, timestamp)
```
*Reinvestment only happens when queue cannot make progress or is empty.*

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator** with **Liquid Staking** characteristics

The vault follows the yield aggregator pattern (deposit underlying → receive share token → yield accrues → exchange rate increases) but without ERC-4626 compliance. The withdrawal queue and exchange-rate-based derivative token add liquid staking characteristics.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| User | Untrusted | Deposit HOLLAR, request/cancel redemptions, transfer HDCL. Escrowed HDCL held by vault during pending redemptions |
| Keeper Bot | Untrusted | Call `pokeDecentral()` and `pokeQueue()` — both permissionless. Drives position lifecycle and queue processing |
| ADMIN_ROLE | Trusted | All operational functions instant: pause/unpause, pauseDeposits/unpauseDeposits, setTvlCap, setMinReinvestAmount, setMinRedeemAmount, setOracle, markPositionStale/unmarkPositionStale. No on-chain timelock on any action |
| UPGRADER_ROLE | Trusted | Authorize UUPS proxy upgrades — instant, no timelock. Can change all contract logic |
| DEFAULT_ADMIN_ROLE | Trusted | Grant/revoke ADMIN_ROLE and UPGRADER_ROLE. Inherited from AccessControlUpgradeable |

**Adversary Ranking** (ordered by threat level):

1. **Compromised admin/upgrader** — Holds instant, unrestricted power to change oracle, mark positions stale, pause operations, or upgrade the entire contract. No timelock buffer exists.
2. **Share inflation attacker (first depositor)** — Canonical vault attack. Mitigated by DEAD_SHARES but relevant to verify the mitigation's completeness.
3. **Exchange rate manipulator** — Manipulates `totalAssets()` to inflate/deflate share price. The vault uses internal accounting (not `balanceOf`) for invested principal, reducing direct donation attack surface. However, `idleHollar` is an internal counter — discrepancies between it and actual HOLLAR balance could arise.
4. **Queue front-runner** — Exploits timing between exchange rate changes and queue processing to receive HOLLAR at favorable rates.
5. **Decentral Pool failure** — If the external Decentral Pool is compromised, paused, or becomes insolvent, all vault principal is at risk with no diversification or emergency withdrawal mechanism.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

1. **Vault ↔ Decentral Pool**: The vault fully trusts DecentralPool to correctly handle deposits, yield calculations, approval flows, and principal returns. If Decentral withholds approvals, positions become stuck (mitigated by `markPositionStale`). If Decentral returns less principal/yield than expected, `idleHollar` tracking diverges from actual balance.

2. **Admin boundary**: ADMIN_ROLE controls oracle address (instant change), TVL cap, stale marking, and pause. All operations execute instantly with no delay. `markPositionStale` freezes a position's yield at current level and moves its value to `totalStaleValue` — admin can manipulate this to affect `totalAssets()` and therefore exchange rate.

3. **Upgrader boundary**: UPGRADER_ROLE can replace the entire implementation via UUPS. This is the highest-privilege action — full fund extraction possible through malicious upgrade.

4. **Oracle boundary**: `setOracle` instantly changes the oracle address. The oracle is used by `getOraclePrice()` (view function) and by WDCLOracle for external consumers — not directly in vault accounting. However, if downstream protocols (e.g., Aave) rely on WDCLOracle, a malicious oracle change has external blast radius.

### Key Attack Surfaces

- **ADMIN_ROLE / UPGRADER_ROLE compromise** — All admin functions are instant with no timelock. `setOracle` can redirect the price feed, `markPositionStale` manipulates `totalAssets()`, and UUPS upgrade can replace all logic. A compromised admin EOA has unlimited extraction capability. `markPositionStale`/`unmarkPositionStale` in particular can shift value between `totalStaleValue` and active accounting, affecting exchange rate for all holders.

- **Exchange rate manipulation via totalAssets()** — `totalAssets()` is computed from four components: `totalInvestedPrincipal`, accrued yield (O(1) via `yieldRateSum`/`yieldOffsetSum`), `idleHollar`, and `totalStaleValue`. The accrued yield calculation `(block.timestamp * yieldRateSum - yieldOffsetSum) / (SECONDS_PER_YEAR * WAD)` involves large intermediate values — overflow is possible with very large principals and high APYs. Rounding in deposit (line 325: `hollarAmount * supply / assets`) and queue processing (line 871, 894) determines who gains/loses fractional value.

- **Redemption queue fairness and rate snapshot** — Queue processing uses the exchange rate at time of `_processQueueWithHollar` call, not at time of request submission. Between request and fulfillment, the exchange rate may change significantly. The `MAX_QUEUE_ITERATIONS = 50` cap means large queues process incrementally — a keeper can choose when to call `pokeQueue()`, selecting favorable rate moments. Partial fulfillment (line 894: `hdclToBurn = available * WAD / rate`) and full fulfillment (line 871: `hollarValue = remainingHdcl * rate / WAD`) use inverse formulas — rounding direction may not be symmetric.

- **Decentral Pool external dependency** — All vault funds flow through DecentralPool. The vault has zero diversification — a single pool failure locks 100% of invested assets. The `try/catch` pattern in `pokeDecentral` silently swallows errors, potentially masking Decentral-side issues. There is no emergency withdrawal mechanism that bypasses the Decentral approval flow.

- **Stale position accounting** — `markPositionStale` removes a position from active yield calculation and snapshots its value into `totalStaleValue`. On `pokeDecentral` for stale positions (lines 431-433, 467-468), `totalStaleValue` is decremented. If the actual yield/principal received differs from the stale snapshot values, the delta impacts `totalAssets()` without compensation — positive difference benefits all holders, negative difference dilutes them.

### Upgrade Architecture Concerns

- **No timelock on UUPS upgrades** — `_authorizeUpgrade` only requires `UPGRADER_ROLE` with no delay. A compromised upgrader key can deploy a malicious implementation instantly.
- **No storage gap** — `HDCLVault.sol` does not declare `uint256[N] private __gap`. Future upgrades that add parent contracts or reorder storage could cause storage collisions.
- **Implementation not self-destructed** — Constructor calls `_disableInitializers()` which prevents initialization of the implementation, but the implementation contract itself remains callable for view functions.

### Protocol-Type Concerns

**As a Yield Aggregator:**
- Share price calculation at `totalSupply == 0` returns `WAD` (1:1). The DEAD_SHARES mitigation (1000 wei to `0xdead`) prevents the classic inflation attack, but the minimum first deposit must exceed DEAD_SHARES (line 318). Verify this threshold is sufficient for the HOLLAR decimal precision.
- `totalAssets()` uses purely internal accounting — `totalInvestedPrincipal`, `yieldRateSum`/`yieldOffsetSum`, `idleHollar`, `totalStaleValue`. This means direct HOLLAR donations to the vault are NOT reflected in `totalAssets()`, creating a permanent accounting gap between real balance and tracked assets.
- The vault does not implement ERC-4626, so standard vault integration tools and security assumptions do not apply. Custom integrations must handle the async redemption queue model.

**As Liquid Staking:**
- The withdrawal queue creates illiquidity risk. If positions take 60+ days to mature (Decentral's `minimumInvestmentPeriodSeconds`) plus withdrawal delay, redeemers face extended wait times. No secondary market mechanism exists on-chain.
- Exchange rate can only increase from yield, but `markPositionStale` followed by `unmarkPositionStale` resets `yieldStartTime` to `block.timestamp`, effectively erasing accrued yield for that position's contribution to the rate.

### Temporal Risk Profile

**Deployment & Initialization:**
- `initialize()` uses `initializer` modifier — safe against re-initialization. However, the proxy deployment and `initialize()` call should be atomic (same transaction) to prevent front-running.
- Initial state: `totalSupply == 0` allows first-depositor dynamics. DEAD_SHARES mitigation is present but only activates when the first real deposit occurs.
- Roles (`DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `UPGRADER_ROLE`) are all granted to `_admin` parameter in `initialize()`. If this is an EOA, there's a single-key risk window until roles are transferred to a multisig.

**Market Stress:**
- If Decentral Pool becomes illiquid or pauses withdrawals, the vault cannot process position redemptions. `markPositionStale` is the only admin recourse — it preserves `totalAssets()` accuracy but doesn't recover funds.
- A large number of redemption requests during stress would queue up, and `MAX_QUEUE_ITERATIONS = 50` limits throughput per `pokeQueue()` call.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **DecentralPool** — via `HDCLVault:deposit`, `requestYieldWithdrawal`, `executeYieldWithdrawal`, `requestPrincipalWithdrawal`, `executePrincipalWithdrawal`
> - Assumes: Correct yield calculation based on `fixedAPYWad`, timely approval of withdrawals, principal returned in full
> - Validates: NONE — vault uses `try/catch` on execute calls but does not validate amounts returned
> - Mutability: External contract, likely upgradeable (has UPGRADER_ROLE in interface)
> - On failure: `try/catch` silently returns — position stays in current state, retried on next `pokeDecentral()` call

> **PoolToken (NFT)** — via `DecentralPool` (indirect — vault receives NFTs via `onERC721Received`)
> - Assumes: NFTs are minted correctly on deposit, ownership tracked correctly
> - Validates: `onERC721Received` returns correct selector
> - Mutability: External contract
> - On failure: Deposit would revert if NFT mint fails

> **HOLLAR (Stablecoin)** — via `safeTransferFrom`, `safeTransfer`, `safeApprove`
> - Assumes: Standard ERC-20 behavior, no fee-on-transfer, no rebasing, no blacklisting
> - Validates: Uses SafeERC20 for all interactions
> - Mutability: Unknown — if HOLLAR is upgradeable, behavior could change
> - On failure: SafeERC20 reverts on failed transfer

> **IAggregatorV3Interface (Oracle)** — via `HDCLVault.getOraclePrice()`, `WDCLOracle.latestRoundData()`
> - Assumes: Positive price answer, correct decimals
> - Validates: `require(answer > 0)` in getOraclePrice; no staleness check
> - Mutability: Oracle address changeable instantly by admin
> - On failure: Reverts with "Invalid oracle price"

**Token Assumptions** (unvalidated):
- HOLLAR: assumes no fee-on-transfer — impact if violated: `idleHollar` tracker would overstate actual balance, leading to failed transfers during queue fulfillment
- HOLLAR: assumes no rebasing — impact if violated: `totalAssets()` would not reflect balance changes from rebasing, causing exchange rate drift

---

## 3. Invariants

### Stated Invariants

- **Dead shares prevent inflation**: "Dead shares minted on first deposit to mitigate inflation attack" (`HDCLVault.sol:39`). DEAD_SHARES = 1000 minted to `0xdead` on first deposit.

### Inferred Invariants

- **Accounting identity**: `totalAssets() == totalInvestedPrincipal + accruedYield + idleHollar + totalStaleValue`. Derived from `HDCLVault:totalAssets()`. If violated: exchange rate becomes incorrect, all deposits/redemptions use wrong price.
- **Bucket consistency**: `yieldRateSum == Σ(apyWad_i × principal_i)` and `yieldOffsetSum == Σ(apyWad_i × principal_i × yieldStartTime_i)` for all non-stale positions. Derived from `_addToBucket`/`_removeFromBucket`. If violated: accrued yield calculation returns wrong value.
- **Queue HDCL accounting**: `totalQueuedHdcl == Σ(hdclAmount - hdclFulfilled)` for all active queue entries. Derived from `requestRedeem`/`cancelRedeem`/`_processQueueWithHollar`. If violated: queue processing under/over-distributes HOLLAR.
- **Position state monotonicity**: NFTState transitions only forward: Active → YWR → YC → PWR → Redeemed. Derived from `pokeDecentral` state machine. If violated: positions could be double-processed.
- **Escrowed HDCL**: `balanceOf(address(vault)) >= totalQueuedHdcl`. HDCL is transferred to vault on `requestRedeem` and burned on fulfillment. If violated: queue fulfillment reverts.
- **Exchange rate monotonicity**: Exchange rate should only increase over time from yield accrual, never decrease (absent admin stale operations). Derived from the non-rebasing model design.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing | No README in hdcl-vault/ |
| NatSpec | Present | Good coverage on public functions in HDCLVault.sol; WDCLOracle has doc comments |
| Spec/Whitepaper | Missing | No spec or whitepaper found |
| Inline Comments | Adequate | Key sections have headers and brief inline comments; internal functions documented |

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

- **No fuzz testing**: The exchange rate math (`totalAssets`, `yieldRateSum`/`yieldOffsetSum` calculations) involves large intermediate products and division — high priority for stateless fuzz to find overflow/rounding edge cases.
- **No stateful/invariant testing**: The position lifecycle state machine (5 states with transitions) and redemption queue (partial fulfillment, cancellation, head advancement) are prime candidates for invariant testing to verify accounting consistency.
- **No formal verification**: The core accounting invariants (bucket consistency, queue HDCL tracking, exchange rate monotonicity) are suitable for formal verification.
- **Branch coverage at 64%**: Significant untested branches in HDCLVault — likely edge cases in queue processing, stale position handling, and TVL cap enforcement.

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
| Test co-change rate | Could not determine | Git analysis path mismatch; tests are visibly co-modified in recent commits |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| HDCLVault.sol | 9 | Highest churn — prioritize review |
| WDCLOracle.sol | 2 | Stable after initial creation |
| IDecentralPool.sol | 2 | Interface evolution |
| IHDCLVault.sol | 2 | Interface evolution |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals: message keywords, diff patterns, change shape. **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| f0c4eac | 2026-03-26 | zero-address checks, oracle pause revert, stale yield fix, TVL cap guard, reinvest cap fix | 10 | Explicit security + oracle/pricing |
| f2e2f10 | 2026-03-24 | Interface fixes, max hollar approval removed, processQueue removed from deposit | 8 | Explicit security language |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| openzeppelin-contracts | lib/openzeppelin-contracts | OpenZeppelin | Submodule | Standard — pragma variations are OZ's own multi-version support |
| openzeppelin-contracts-upgradeable | lib/openzeppelin-contracts-upgradeable | OpenZeppelin | Submodule | Standard |

### Security Observations

- **Rapid development cycle**: 10 commits in ~3 days with significant logic changes (queue refactoring, stale position handling, TVL cap fixes). High velocity increases defect risk.
- **Two-contributor codebase**: Initial scaffold by lolmcshizz (1436 LOC), all subsequent modifications by Yash Sharma. Single-developer modification pattern limits peer review of changes.
- **Security-scored commit f0c4eac (score 10)**: Contains 5 distinct fixes in one commit — zero-address checks, oracle pause behavior, stale yield double-count fix, TVL cap guard, and reinvest cap fix. Each fix addresses a real vulnerability. The bundling suggests these were found during review rather than individual regression.
- **Approval handling changes**: f2e2f10 explicitly removed max HOLLAR approval "for security reasons" — indicates security awareness in development.
- **No fuzz or formal verification**: For a vault handling real stablecoin deposits with complex O(1) yield math, the absence of property-based testing is a significant gap.

### Cross-Reference Synthesis

- **HDCLVault.sol** is both the highest-churn file (9 modifications) AND the sole contract with all attack surfaces identified in Section 2 — prioritize for deep review.
- Security commit f0c4eac fixes stale yield double-counting and TVL cap underflow — both relate to the "Stale position accounting" and "Exchange rate manipulation" attack surfaces in Section 2.
- The rapid development pace (10 commits in 3 days) with multiple security fixes suggests the codebase is still stabilizing — inferred invariants in Section 3 may not all hold under edge cases.
- Branch coverage at 64% aligns with the "Queue fairness" and "Stale position" attack surfaces — these are likely the untested branches.

---

## X-Ray Verdict

**FRAGILE** — Unit tests exist with good coverage (88% line) but no fuzz, invariant, or formal verification for a vault with non-trivial O(1) yield math and async queue processing. All admin operations are instant with no on-chain timelock.

**Structural facts:**
1. 677 nSLOC across 2 in-scope contracts (HDCLVault + WDCLOracle), with HDCLVault comprising 92% of the codebase
2. 78 unit tests passing with 88% line / 64% branch coverage on HDCLVault; 0 fuzz tests, 0 invariant tests, 0 formal verification
3. UUPS upgradeable with no timelock — UPGRADER_ROLE can replace implementation instantly
4. 2 contributors to source; all 9 post-initial modifications by a single developer over 3 days
5. 10 admin functions, all instant execution — no on-chain delay mechanism for any privileged action
