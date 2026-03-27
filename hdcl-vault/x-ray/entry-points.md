# Entry Point Map

> HDCL Vault | 17 entry points | 5 permissionless | 0 role-gated | 11 admin-only
> Spec: `.claude/HDCL-vault-specification.md` v0.1

---

## Protocol Flow Paths

### Setup (Admin)

`initialize()` → `setOracle()` → `setTvlCap()` → `setWithdrawalDelay()` → seed initial deposit (per spec §9)

### User Deposit Flow

`[setup]` → `User.deposit(hollarAmount)` → `DecentralPool.deposit()` → NFT position created → hDCL minted

### User Redemption Flow

`[deposit]` → `User.requestRedeem(hdclAmount)` → hDCL escrowed (per spec: NOT burned)
                                                  ├─→ `User.cancelRedeem(requestId)` → hDCL returned
                                                  └─→ `pokeQueue()` → HOLLAR transferred at fulfillment-time rate

### Position Lifecycle (Keeper)

`[deposit]` → [60 days] → `pokeDecentral(i)` Active→YWR
                          → `pokeDecentral(i)` YWR→YC  ◄── Decentral approval (48h SLA per spec)
                          → `pokeDecentral(i)` YC→PWR  ◄── try/catch (spec fix)
                          → `pokeDecentral(i)` PWR→Redeemed  ◄── approval + delay
                          └─→ auto-processes queue

### Reinvestment

`[queue empty or can't progress]` → `pokeQueue()` → `_reinvest()` → new position

---

## Permissionless

### `HDCLVault.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Parameters | `hollarAmount` (user-controlled) |
| Call chain | `→ totalAssets() + hollarAmount > tvlCap check → hollar.safeTransferFrom → _mint → DecentralPool.deposit → _addToBucket` |
| State modified | `positions[]`, `apyBuckets`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum`, ERC-20 balances |
| Value flow | user → Vault → DecentralPool |
| Reentrancy guard | yes |

### `HDCLVault.requestRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Parameters | `hdclAmount` (user-controlled); must be >= `minRedeemAmount` |
| Call chain | `→ _transfer(user, vault) → redemptionQueue[queueTail] → queueTail++ → totalQueuedHdcl +=` |
| State modified | `redemptionQueue[]`, `queueTail`, `totalQueuedHdcl`, ERC-20 balances |
| Value flow | user → Vault (hDCL escrow) |
| Reentrancy guard | yes |

### `HDCLVault.cancelRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**no** whenNotPaused — intentional per design) |
| Parameters | `requestId` (user-controlled); must be own request |
| Call chain | `→ totalQueuedHdcl -= → _transfer(vault, user) → delete redemptionQueue[requestId]` |
| State modified | `redemptionQueue[]`, `totalQueuedHdcl`, ERC-20 balances |
| Value flow | Vault → user (hDCL returned) |
| Reentrancy guard | yes |

### `HDCLVault.pokeDecentral()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Parameters | `positionIndex` (user-controlled) |
| Call chain | State machine: `requestYieldWithdrawal → try executeYieldWithdrawal → try requestPrincipalWithdrawal → try executePrincipalWithdrawal → _processQueueWithHollar` |
| State modified | `positions[i].state/stateChangedAt`, `apyBuckets`, `yieldRateSum`, `yieldOffsetSum`, `totalInvestedPrincipal`, `idleHollar`, `totalStaleValue`, `positionHead`, `redemptionQueue[]`, `queueHead`, `totalQueuedHdcl` |
| Value flow | DecentralPool → Vault → possibly queue users |
| Reentrancy guard | yes |

### `HDCLVault.pokeQueue()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Parameters | none |
| Call chain | `→ _processQueueWithHollar(idleHollar, rate) → [if can't progress] _reinvest() → DecentralPool.deposit()` |
| State modified | `redemptionQueue[]`, `queueHead`, `totalQueuedHdcl`, `idleHollar`, `positions[]`, `apyBuckets`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum` |
| Value flow | Vault → queue users (fulfillment) or Vault → DecentralPool (reinvestment) |
| Reentrancy guard | yes |

---

## Admin-Only

All gated by `onlyRole(ADMIN_ROLE)`.

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| HDCLVault | `pauseDeposits()` | none | `depositsPaused = true` |
| HDCLVault | `unpauseDeposits()` | none | `depositsPaused = false` |
| HDCLVault | `pause()` | none | PausableUpgradeable paused state |
| HDCLVault | `unpause()` | none | PausableUpgradeable unpaused |
| HDCLVault | `setTvlCap(uint256)` | `newCap`; requires `>= totalAssets()` | `tvlCap` |
| HDCLVault | `setMinReinvestAmount(uint256)` | `amount` | `minReinvestAmount` |
| HDCLVault | `setMinRedeemAmount(uint256)` | `amount` | `minRedeemAmount` |
| HDCLVault | `setOracle(address)` | `_oracle`; zero-check | `oracle` |
| HDCLVault | `markPositionStale(uint256)` | `positionIndex`; guards: YWR/YC/PWR state + withdrawalDelay | `totalStaleValue`, bucket removal, `stalePrincipal`, `staleYield` (0 for PWR/YC) |
| HDCLVault | `unmarkPositionStale(uint256, bool)` | `positionIndex`, `backtrackYield` | reverse stale accounting; if backtrack: back-calculate yieldStartTime |
| HDCLVault | `setWithdrawalDelay(uint256)` | `_withdrawalDelay` | `withdrawalDelay` |

---

## Initialization

### `HDCLVault.initialize()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, initializer |
| Parameters | `_decentralPool`, `_poolToken`, `_hollar` (zero-checked), `_tvlCap`, `_withdrawalDelay`, `_admin` (zero-checked) |
| State modified | All initializable state; roles granted to `_admin` |
| Spec ref | §9 — deploy impl → proxy → initialize → seed deposit |
