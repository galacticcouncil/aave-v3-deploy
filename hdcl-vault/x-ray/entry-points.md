# Entry Point Map

> HDCL Vault | 16 entry points | 5 permissionless | 0 role-gated | 10 admin-only

---

## Protocol Flow Paths

### Setup (Admin)

`initialize()` → `setOracle()` → `setTvlCap()` → `setMinReinvestAmount()`

### User Deposit Flow

`[admin setup above]` → `User.deposit(hollarAmount)` → `DecentralPool.deposit()` → NFT position created
                                                      └─→ HDCL minted to user

### User Redemption Flow

`[deposit above]` → `User.requestRedeem(hdclAmount)` → HDCL escrowed
                                                       ├─→ `User.cancelRedeem(requestId)` → HDCL returned
                                                       └─→ `pokeQueue()` → HOLLAR transferred to user  ◄── requires idleHollar

### Position Lifecycle (Keeper)

`[deposit above]` → [maturityTime passes] → `pokeDecentral(i)` Active→YWR
                                            → `pokeDecentral(i)` YWR→YC  ◄── requires Decentral approval
                                            → `pokeDecentral(i)` YC→PWR
                                            → `pokeDecentral(i)` PWR→Redeemed  ◄── requires approval + delay
                                            └─→ idleHollar increased → auto-processes queue

### Reinvestment (Keeper)

`[position redeemed above, queue empty]` → [idleHollar >= minReinvestAmount] → `pokeQueue()` → `_reinvest()` → new position

---

## Permissionless

### `HDCLVault.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | User |
| Parameters | `hollarAmount` (user-controlled) |
| Call chain | `→ hollar.safeTransferFrom(user, vault) → _mint(user, hdclMinted) → hollar.safeApprove(decentralPool) → DecentralPool.deposit(hollarAmount) → _addToBucket()` |
| State modified | `positions[]`, `apyBuckets[apyWad]`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum`, `activeAPYList[]`, `isActiveAPY[]`, ERC-20 balances |
| Value flow | Tokens: user → Vault → DecentralPool |
| Reentrancy guard | yes |

### `HDCLVault.requestRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | User |
| Parameters | `hdclAmount` (user-controlled) |
| Call chain | `→ _transfer(user, vault, hdclAmount) → redemptionQueue[queueTail] = new request → queueTail++ → totalQueuedHdcl += hdclAmount` |
| State modified | `redemptionQueue[]`, `queueTail`, `totalQueuedHdcl`, ERC-20 balances (HDCL transferred to vault escrow) |
| Value flow | Tokens: user → Vault (HDCL escrow) |
| Reentrancy guard | yes |

### `HDCLVault.cancelRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | Original request owner (verified via `request.user != msg.sender` check) |
| Parameters | `requestId` (user-controlled) |
| Call chain | `→ totalQueuedHdcl -= remaining → _transfer(vault, user, remaining) → delete redemptionQueue[requestId]` |
| State modified | `redemptionQueue[requestId]` (deleted), `totalQueuedHdcl`, ERC-20 balances |
| Value flow | Tokens: Vault → user (HDCL returned from escrow) |
| Reentrancy guard | yes |

### `HDCLVault.pokeDecentral()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Anyone (keeper bot expected) |
| Parameters | `positionIndex` (user-controlled) |
| Call chain | `→ DecentralPool.requestYieldWithdrawal() → DecentralPool.executeYieldWithdrawal() → _adjustBucketOnYieldClaim() → DecentralPool.requestPrincipalWithdrawal() → DecentralPool.executePrincipalWithdrawal() → _adjustBucketOnPrincipalRedemption() → _advancePositionHead() → _processQueueWithHollar()` |
| State modified | `positions[i].state`, `apyBuckets[]`, `yieldRateSum`, `yieldOffsetSum`, `totalInvestedPrincipal`, `idleHollar`, `totalStaleValue`, `positionHead`, `redemptionQueue[]`, `queueHead`, `totalQueuedHdcl`, ERC-20 balances |
| Value flow | Tokens: DecentralPool → Vault (yield + principal) → possibly Vault → queue users (HOLLAR) |
| Reentrancy guard | yes |

### `HDCLVault.pokeQueue()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Anyone (keeper bot expected) |
| Parameters | none |
| Call chain | `→ _processQueueWithHollar(idleHollar, rate) → [if queue empty] _reinvest() → DecentralPool.deposit()` |
| State modified | `redemptionQueue[]`, `queueHead`, `totalQueuedHdcl`, `idleHollar`, `positions[]`, `apyBuckets[]`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum`, ERC-20 balances |
| Value flow | Tokens: Vault → queue users (HOLLAR fulfillment) or Vault → DecentralPool (reinvestment) |
| Reentrancy guard | yes |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| HDCLVault | `pauseDeposits()` | none | `depositsPaused = true` |
| HDCLVault | `unpauseDeposits()` | none | `depositsPaused = false` |
| HDCLVault | `pause()` | none | PausableUpgradeable paused state |
| HDCLVault | `unpause()` | none | PausableUpgradeable unpaused state |
| HDCLVault | `setTvlCap(uint256)` | `newCap` (admin-provided) | `tvlCap`; requires `newCap >= totalAssets()` |
| HDCLVault | `setMinReinvestAmount(uint256)` | `amount` (admin-provided) | `minReinvestAmount` |
| HDCLVault | `setMinRedeemAmount(uint256)` | `amount` (admin-provided) | `minRedeemAmount` |
| HDCLVault | `setOracle(address)` | `_oracle` (admin-provided); zero-check | `oracle` |
| HDCLVault | `markPositionStale(uint256)` | `positionIndex` (admin-provided) | `positions[i].isStale`, `positions[i].stalePrincipal`, `positions[i].staleYield`, `totalStaleValue`, `apyBuckets[]`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum` |
| HDCLVault | `unmarkPositionStale(uint256)` | `positionIndex` (admin-provided) | `positions[i].isStale`, `positions[i].yieldStartTime`, `positions[i].stalePrincipal`, `positions[i].staleYield`, `totalStaleValue`, `apyBuckets[]`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum` |

---

## Initialization

### `HDCLVault.initialize()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, initializer |
| Caller | Deployer (one-time) |
| Parameters | `_decentralPool` (deployer-provided), `_poolToken` (deployer-provided), `_hollar` (deployer-provided), `_tvlCap` (deployer-provided), `_admin` (deployer-provided) |
| Call chain | `→ __ERC20_init → __AccessControl_init → __UUPSUpgradeable_init → __Pausable_init → __ReentrancyGuard_init → _grantRole(DEFAULT_ADMIN_ROLE, admin) → _grantRole(ADMIN_ROLE, admin) → _grantRole(UPGRADER_ROLE, admin)` |
| State modified | All initializable state: token name/symbol, role assignments, `decentralPool`, `poolToken`, `hollar`, `tvlCap`, `minReinvestAmount` (10e18), `minRedeemAmount` (1e18) |
| Value flow | None |
| Reentrancy guard | N/A (initializer) |
