# HDCLVault Smart Contract Audit

**Date:** 2026-03-13
**Scope:** `hdcl-vault/src/HDCLVault.sol` and supporting contracts
**Commit:** `d2da6ae`

## Architecture Summary

An upgradeable (UUPS) ERC-20 vault that wraps Decentral Protocol NFT lending positions. Users deposit HOLLAR, receive HDCL tokens at an appreciating exchange rate, and redeem via an async FIFO queue backed by position maturity.

---

## CRITICAL

### 1. Exchange rate drift during deposit queue processing

**Location:** `HDCLVault.sol:298-308`

In `deposit()`, HDCL is minted at the exchange rate *before* queue processing. Then `_processQueueWithHollar` burns escrowed HDCL and transfers HOLLAR out, changing both `totalSupply()` and `idleHollar` (and thus `totalAssets()`). The exchange rate used at L303 is computed *after* the mint, so queue redemptions burn HDCL at a slightly diluted rate, leaking small amounts of value from existing holders to queue redeemers on every deposit.

### 2. TVL cap check excludes `totalStaleValue`

**Location:** `HDCLVault.sol:275`

```solidity
if (totalInvestedPrincipal + idleHollar + hollarAmount > tvlCap) revert ExceedsTvlCap();
```

This doesn't account for `totalStaleValue`, which represents real capital held in positions. Marking positions stale effectively frees room under the TVL cap, allowing more deposits than intended.

### 3. Unbounded loop in `totalAssets()`

**Location:** `HDCLVault.sol:241-253`

`activeAPYs` grows without bound. Since `totalAssets()` is called in `deposit()`, `exchangeRate()`, and the oracle's `latestRoundData()`, this could eventually DoS core functions or cause out-of-gas. Also affects `_addToActiveAPYsIfNew()` (L862) and `_removeFromActiveAPYs()` (L874).

---

## HIGH

### 4. First depositor inflation attack mitigation is weak

**Location:** `HDCLVault.sol:41, 279-284`

`DEAD_SHARES = 1000` (1000 wei) provides negligible rounding-loss protection for an 18-decimal token. While the accounting-based `totalAssets()` (rather than `balanceOf`) prevents the classic donation attack, a first depositor depositing exactly `1001` wei can cause significant rounding losses for subsequent small depositors at L287: `hollarAmount * supply / assets`.

**Recommendation:** Increase `DEAD_SHARES` to at least `1e6`.

### 5. `processPosition` can bypass Decentral withdrawal delay

**Location:** `HDCLVault.sol:391-453`

The function uses sequential `if` statements (not `else if`), so a single call can advance through multiple states. When going `YieldClaimed -> PrincipalWithdrawalRequested -> Redeemed` in one call, `requestPrincipalWithdrawal` and `executePrincipalWithdrawal` are called in the same transaction, potentially bypassing the `PRINCIPAL_WITHDRAWAL_DELAY` the Decentral pool enforces.

### 6. `reinvest()` missing `whenNotPaused` modifier

**Location:** `HDCLVault.sol:464`

During an emergency pause, permissionless actors can still reinvest idle HOLLAR into new Decentral positions, locking up liquidity that should remain available.

### 7. Oracle `decimals()` function missing

**Location:** `HDCLVault.sol:643-668`

The contract implements `latestRoundData()` and `getRoundData()` but not `decimals()`. Aave and other Chainlink consumers call `decimals()` to interpret the answer. Without it, integrations will revert.

---

## MEDIUM

### 8. No slippage protection on deposit

**Location:** `HDCLVault.sol:272`

Users cannot specify a minimum HDCL amount. If the exchange rate changes between tx submission and execution, the user may receive fewer HDCL than expected.

### 9. Redemption queue griefing

**Location:** `HDCLVault.sol:352-366`

Anyone can create many small redemption requests, bloating the `redemptionQueue` array and increasing gas costs for `_processQueueWithHollar`. The `queueHead` pointer mitigates for fulfilled requests, but cancelled entries still require iteration.

### 10. `cancelRedeem` doesn't advance `queueHead`

**Location:** `HDCLVault.sol:370-383`

When the request at `queueHead` is cancelled, `queueHead` is not advanced. `_processQueueWithHollar` handles this with a skip-and-increment, but it wastes gas on cancelled entries.

### 11. Fragile dual-tracking of HOLLAR in `deposit()`

**Location:** `HDCLVault.sol:295-343`

`deposit()` tracks HOLLAR via both `idleHollar` (storage) and local `remaining`. `_processQueueWithHollar` decrements `idleHollar` internally. The accounting is currently correct (`hollarUsed + remaining == hollarAmount`) but the dual-tracking pattern is fragile and error-prone for future modifications.

---

## LOW / INFORMATIONAL

### 12. No zero-address checks in `initialize()`

**Location:** `HDCLVault.sol:205-230`

Parameters `_decentralPool`, `_poolToken`, `_hollar`, `_admin` are not validated.

### 13. `setMinReinvestAmount(0)` is allowed

**Location:** `HDCLVault.sol:703-706`

Allows `reinvest()` to be called with dust amounts, creating gas-wasteful tiny Decentral positions.

### 14. No event on `initialize()`

Deployment/initialization doesn't emit events for initial configuration, making off-chain indexing harder.

### 15. `positions` array grows unboundedly

**Location:** `HDCLVault.sol:126`

Append-only array. Over years, iteration in `getEstimatedWaitTime()` becomes expensive. `positionHead` helps for processing but not for view functions.

### 16. `getRoundData` ignores `_roundId` parameter

**Location:** `HDCLVault.sol:652-658`

Always returns the current exchange rate regardless of which round is requested.

### 17. Missing storage gap for upgradeable contract

No `uint256[50] private __gap;` variable. Future upgrades adding state variables could collide with inherited OpenZeppelin storage.

### 18. `type(uint256).max` approval in `initialize()`

**Location:** `HDCLVault.sol:229`

If `decentralPool` is compromised or upgraded maliciously, it could drain all HOLLAR from the vault.

---

## Recommendations Summary

| # | Action | Severity |
|---|--------|----------|
| 1 | Fix exchange rate computation order in `deposit()` to snapshot rate before minting | Critical |
| 2 | Include `totalStaleValue` in TVL cap check | Critical |
| 3 | Cap `activeAPYs.length` or use an enumerable set | Critical |
| 4 | Increase `DEAD_SHARES` to `1e6` | High |
| 5 | Add `whenNotPaused` modifier to `reinvest()` | High |
| 6 | Add `decimals()` returning `18` for oracle compatibility | High |
| 7 | Add `minHdclOut` slippage parameter to `deposit()` | Medium |
| 8 | Add minimum redemption amount to prevent queue griefing | Medium |
| 9 | Advance `queueHead` in `cancelRedeem` when applicable | Medium |
| 10 | Add zero-address checks in `initialize()` | Low |
| 11 | Add `uint256[50] private __gap;` for upgrade safety | Low |
| 12 | Add minimum value for `setMinReinvestAmount` | Low |
