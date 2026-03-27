# X-Ray Report

> HDCL Vault (Hydrated Decentral) | 753 nSLOC | a4f73f9+ (`feat/hdcl-vault`) | Foundry | 26/03/26
> Spec: `.claude/HDCL-vault-specification.md` v0.1 (2026-03-10)

---

## 1. Protocol Overview

**What it does:** A fungible ERC-20 yield-bearing wrapper around Decentral Protocol's fixed-rate NFT lending positions, converting illiquid time-locked NFTs into a single liquid hDCL token (per spec §1).

- **Users**: Depositors provide HOLLAR stablecoin and receive hDCL tokens; redeemers queue hDCL for async conversion back to HOLLAR
- **Core flow**: Deposit HOLLAR → vault deposits into Decentral → receives NFT position → mints hDCL at current exchange rate → yield accrues → exchange rate appreciates (per spec §2)
- **Key mechanism**: Non-rebasing exchange rate model (per spec: "like Bifrost's vDOT"). `totalAssets()` computed in O(1) via `yieldRateSum`/`yieldOffsetSum`. Decentral uses simple interest (per spec §4.3: "This is exact, not an approximation")
- **Token model**: hDCL is the vault share token (ERC-20, 18 decimals). HOLLAR is the underlying stablecoin. Decentral positions are NFTs held by the vault (per spec §3)
- **Admin model**: `ADMIN_ROLE` controls all configuration. `UPGRADER_ROLE` for UUPS. All instant — no on-chain timelock. (Per spec §4.8): "No admin function to withdraw vault funds or NFTs."

For a visual overview, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Vault Core | HDCLVault.sol | 697 | ERC-20 token + vault logic + deposit/redeem/queue/position lifecycle |
| Oracle | WDCLOracle.sol | 56 | Chainlink-compatible price feed for external consumers |

### Spec Deviations

| # | Spec Says | Code Does | Assessment |
|---|-----------|-----------|------------|
| 1 | Oracle in vault (§4.1) | Separate WDCLOracle | Improvement — resolves `decimals()` collision |
| 2 | `processPosition`/`processQueue`/`reinvest` (§4.5-4.7) | `pokeDecentral`/`pokeQueue` (merged) | Renamed + merged. Reinvest when queue can't progress (spec: only when empty) |
| 3 | `totalAssets = principal + yield + idle` (§4.3) | Adds `+ totalStaleValue` | Required for stale feature |
| 4 | Queue as array with `active` field (§4.6) | Mapping with head/tail + delete | Gas optimization |
| 5 | `INVESTMENT_PERIOD` hardcoded (§4.1) | Dynamic from pool | Improvement |
| 6 | `setTvlCap` can decrease (§4.8) | Requires `>= totalAssets()` | Stricter guard |
| 7 | No `minRedeemAmount` | Added (1 hDCL default) | DoS protection |
| 8 | No `setOracle`, `setWithdrawalDelay`, `setMinRedeemAmount` | Added | Extra admin functions |
| 9 | `WithdrawalDelayed` event logic (§4.8) | Emitted in try/catch blocks on stuck positions | Implemented via `2 * withdrawalDelay` threshold |
| 10 | `markPositionStale` only for YWR/PWR (§4.5) | Also accepts YieldClaimed | Covers try/catch gap on `requestPrincipalWithdrawal` |
| 11 | Name "Wrapped Decentral" / Symbol "HDCL" (§3) | "Hydrated Decentral" / "hDCL" | Updated branding |
| 12 | No `backtrackYield` on unmark | `unmarkPositionStale(positionIndex, bool)` | Admin can preserve or forfeit pre-stale yield |
| 13 | No `withdrawalDelay` config | Init param + `setWithdrawalDelay()` | Configurable stale guard |
| 14 | No `stateChangedAt` tracking | Added to NFTPosition | Enables withdrawal-delay guard |
| 15 | No storage gap | `uint256[50] private __gap` | UUPS upgrade safety |
| 16 | Stale yield = live formula for all states | `currentYield = 0` for PWR/YC states | Prevents phantom yield inflation |
| 17 | Stale yield deduction = full `staleYield` | `min(staleYield, yieldReceived)` | Prevents accounting discrepancy |

### How It Fits Together

The core trick: The vault abstracts Decentral's fixed-rate NFT positions into a fungible token by tracking principal and APY in aggregate buckets, computing yield in O(1) via `yieldRateSum` and `yieldOffsetSum` (per spec §4.3).

### Deposit Flow

```
User
└─ HDCLVault.deposit(hollarAmount)
   ├─ TVL cap check: totalAssets() + hollarAmount <= tvlCap
   ├─ Calculate hdclMinted at current exchangeRate
   ├─ hollar.safeTransferFrom(user → vault)
   ├─ _mint(user, hdclMinted)
   ├─ DecentralPool.deposit(hollarAmount) → tokenId
   └─ _addToBucket(apyWad, principal, timestamp)
```
*First deposit mints DEAD_SHARES (1000) to 0xdead (per spec §4.2).*

### Position Lifecycle (pokeDecentral)

```
Anyone
└─ HDCLVault.pokeDecentral(positionIndex)
   ├─ Active → YieldWithdrawalRequested
   │  └─ DecentralPool.requestYieldWithdrawal(tokenId)
   ├─ YieldWithdrawalRequested → YieldClaimed
   │  ├─ try DecentralPool.executeYieldWithdrawal  ◄── requires approval
   │  ├─ Stale: deduct min(staleYield, yieldReceived) from totalStaleValue
   │  └─ idleHollar += yieldReceived
   ├─ YieldClaimed → PrincipalWithdrawalRequested
   │  └─ try DecentralPool.requestPrincipalWithdrawal  ◄── try/catch (spec fix)
   └─ PrincipalWithdrawalRequested → Redeemed
      ├─ try DecentralPool.executePrincipalWithdrawal  ◄── requires approval + delay
      └─ _processQueueWithHollar(idleHollar, rate)
```
*All Decentral calls use try/catch. WithdrawalDelayed emitted when stuck > 2×withdrawalDelay.*

### Redemption Queue (pokeQueue)

```
Anyone
└─ HDCLVault.pokeQueue()
   ├─ _processQueueWithHollar(idleHollar, rate)
   │  ├─ FIFO: iterate queueHead → queueTail (max 50)
   │  └─ Full or partial fulfillment at current exchangeRate
   └─ If queue can't progress → _reinvest()
```
*(Per spec §4.6): hDCL escrowed but NOT burned at request time — rate-neutral.*

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator** with **Liquid Staking** characteristics

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| User | Untrusted | Deposit HOLLAR, request/cancel redemptions, transfer hDCL |
| Keeper Bot | Untrusted | Call `pokeDecentral()` and `pokeQueue()` — permissionless (per spec §5) |
| ADMIN_ROLE | Trusted | All operational functions instant: pause, setTvlCap, setOracle, markPositionStale, setWithdrawalDelay, etc. (Per spec §4.8): no fund extraction path |
| UPGRADER_ROLE | Trusted | UUPS proxy upgrade — instant, no timelock |
| DEFAULT_ADMIN_ROLE | Trusted | Grant/revoke roles |

**Adversary Ranking:**

1. **Compromised admin/upgrader** — Instant unrestricted power. `setOracle` redirects price feed, `markPositionStale` manipulates totalAssets (now guarded by withdrawal-delay + state checks), UUPS upgrade replaces all logic.
2. **Share inflation attacker** — Mitigated by DEAD_SHARES (per spec §6.2). `totalAssets()` uses internal accounting, not `balanceOf` — donation-resistant.
3. **Queue front-runner** — Rate at fulfillment time, not request time (per spec §4.6: "user continues to earn yield while waiting"). Keeper timing affects rate.
4. **Queue tombstone griefer** — Cancelled entries consume `MAX_QUEUE_ITERATIONS` budget. Low-cost DoS on queue processing.
5. **Decentral Pool failure** — 100% of invested funds in one external pool. `markPositionStale` + try/catch provide recovery paths.

See [entry-points.md](entry-points.md) for the full entry point map.

### Trust Boundaries

1. **Vault ↔ Decentral Pool**: Full trust. (Per spec §6.2): "Legal SLA guarantees 48-hour turnaround." All Decentral calls wrapped in try/catch. `WithdrawalDelayed` emitted when stuck > `2 * withdrawalDelay`.
2. **Admin boundary**: All operations instant. (Per spec §4.8): no fund extraction. `markPositionStale` guarded by withdrawal-delay + state checks (YWR/YC/PWR only). Phantom yield prevented for PWR/YC states.
3. **Upgrader boundary**: UUPS instant upgrade. Highest privilege — full fund extraction via malicious impl.
4. **Oracle boundary**: `setOracle` (not in spec) instantly redirects external consumers. WDCLOracle consumed by Aave.

### Key Attack Surfaces

- **Queue tombstone DoS** — Cancelled entries consume `iterations++` in `_processQueueWithHollar`. An attacker with 50 × minRedeemAmount hDCL (recovered on cancel) can waste all 50 MAX_QUEUE_ITERATIONS per `pokeQueue` call. Fix: move `iterations++` after the zero-address skip.
- **ADMIN_ROLE / UPGRADER_ROLE compromise** — All instant. No timelock on any admin action or UUPS upgrade.
- **Decentral Pool dependency** — Zero diversification. `try/catch` + `markPositionStale` provide degraded-mode operation but no emergency withdrawal bypassing Decentral.

### Upgrade Architecture Concerns

- **No timelock on UUPS upgrades** — `_authorizeUpgrade` only requires `UPGRADER_ROLE`.
- **Storage gap present** — `uint256[50] private __gap` declared. Future upgrades can safely add state variables.
- **Implementation protection** — `_disableInitializers()` in constructor.

### Protocol-Type Concerns

**As a Yield Aggregator:**
- DEAD_SHARES (1000) inflation protection. `totalAssets()` uses internal accounting (donation-resistant).
- Not ERC-4626 compliant — async redemption model.

**As Liquid Staking:**
- Withdrawal queue: max ~62 days (per spec §1). Secondary market via stableswap (out of scope).
- `unmarkPositionStale(backtrackYield=true)` preserves pre-stale yield; `false` forfeits it.

### Temporal Risk Profile

**Deployment & Initialization:**
- `initializer` modifier prevents re-init. (Per spec §9): seed initial deposit to establish 1:1 rate.
- All roles granted to `_admin` — single-key risk until transfer.

### Composability & Dependency Risks

> **DecentralPool** — via deposit/requestYieldWithdrawal/executeYieldWithdrawal/requestPrincipalWithdrawal/executePrincipalWithdrawal
> - Assumes: Correct yield per `fixedAPYWad`, timely approval (per spec: 48h SLA)
> - Validates: NONE — try/catch on executes, no amount validation
> - On failure: Silent return, retry next `pokeDecentral`

> **HOLLAR** — via safeTransferFrom/safeTransfer/safeApprove
> - Assumes: Standard ERC-20, no fee-on-transfer, no rebasing
> - Validates: SafeERC20

> **IAggregatorV3Interface (Oracle)** — via getOraclePrice
> - Assumes: Positive price, correct decimals
> - Validates: `answer > 0`; no staleness check

---

## 3. Invariants

### Stated Invariants (per spec §6.3)

1. `totalSupply() > 0 ⟹ totalAssets() > 0`
2. `idleHollar <= hollar.balanceOf(address(this))`
3. `totalQueuedHdcl <= balanceOf(address(vault))`
4. Every NFT in positions[] with state != Redeemed owned by vault
5. `exchangeRate()` monotonically non-decreasing (normal operation)
6. Yield always claimed before principal (enforced by state machine)

### Stated Invariants (per spec, elsewhere)

7. No admin extraction (per spec §4.8) — verified: no withdraw/transferNFT function
8. Donation resistance (per spec §6.2) — verified: `totalAssets()` uses `idleHollar`, not `balanceOf`
9. Queue rate neutrality (per spec §4.6) — rate calculated once per batch, mathematically invariant through proportional redemptions

### Inferred Invariants (per code)

- `totalAssets() == totalInvestedPrincipal + accruedYield + idleHollar + totalStaleValue`
- `yieldRateSum == Σ(apyWad × principal)` for all non-stale positions
- `yieldOffsetSum == Σ(apyWad × principal × yieldStartTime)` for all non-stale positions
- `totalQueuedHdcl == Σ(hdclAmount - hdclFulfilled)` for active queue entries
- Position state transitions monotonically forward: Active → YWR → YC → PWR → Redeemed
- `staleYieldDeduction <= min(staleYield, yieldReceived)` — prevents over-decrement of totalStaleValue
- `currentYield = 0` for PWR/YC positions in `markPositionStale` — prevents phantom yield

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing | No README in hdcl-vault/ |
| NatSpec | Present | Good coverage on public functions |
| Spec/Whitepaper | Present | `.claude/HDCL-vault-specification.md` v0.1 (52KB, 1047 lines) — comprehensive |
| Inline Comments | Adequate | Key sections documented; stale logic well-commented |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 8 | File scan |
| Test functions | 81 | File scan |
| Line coverage | ~88% (HDCLVault), 100% (WDCLOracle) | forge coverage (prior run) |
| Branch coverage | ~64% (HDCLVault), ~67% (WDCLOracle) | forge coverage (prior run) |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 81 | HDCLVault (deposit, exchange rate, redemption queue, position processing, admin, reinvest, first depositor, stale marking), WDCLOracle |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry) | 0 | none |
| Formal Verification | 0 | none |

### Gaps

- **No fuzz testing**: O(1) yield math with large products needs stateless fuzz for overflow/rounding edge cases
- **No invariant testing**: 9 spec-stated invariants, none encoded as property tests
- **Branch coverage at ~64%**: Untested branches likely in stale position edge cases and queue partial fulfillment

---

## 6. Developer & Git History

> Analyzed branch: `feat/hdcl-vault` at `a4f73f9+` (with uncommitted fixes)

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| lolmcshizz | 1 | +1436 / -0 | 64% |
| Yash Sharma | 9+ | +805+ / -329+ | 36%+ |

### Security-Relevant Commits

| SHA | Date | Subject | Score |
|-----|------|---------|------:|
| f0c4eac | 2026-03-26 | zero-address checks, oracle pause, stale yield fix, TVL cap guard, reinvest cap fix | 10 |
| f2e2f10 | 2026-03-24 | Interface fixes, max hollar approval removed for security | 8 |

### Security Observations

- Active development with multiple security fixes bundled in recent commits
- 5 audit findings from automated scan identified and fixed during this review session
- `markPositionStale` guard, phantom yield fix, stale yield reconciliation, TVL cap fix, reinvest underflow guard — all applied
- Queue tombstone DoS is the only remaining confirmed finding from the latest audit run

---

## X-Ray Verdict

**FRAGILE** — 81 unit tests with ~88% line coverage but no fuzz, invariant, or formal verification for a vault with non-trivial O(1) yield math and 9 spec-stated invariants. All admin operations instant with no on-chain timelock. Comprehensive spec exists with 17 documented deviations, all intentional improvements or additions. 5 audit findings identified and fixed; 1 remaining (queue tombstone DoS).

**Structural facts:**
1. 753 nSLOC across 2 in-scope contracts (HDCLVault 697 + WDCLOracle 56)
2. 81 unit tests passing with ~88% line / ~64% branch coverage; 0 fuzz, 0 invariant, 0 formal verification
3. UUPS upgradeable with storage gap (`__gap[50]`), no timelock on upgrades
4. 2 source contributors; all post-initial modifications by a single developer
5. Comprehensive spec (1047 lines) with 17 documented code deviations — all intentional
6. 5 security audit findings fixed during review; 1 remaining (queue tombstone iteration DoS)
