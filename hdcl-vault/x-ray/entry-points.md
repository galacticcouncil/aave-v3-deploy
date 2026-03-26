# Entry Point Map

> HDCL Vault | 16 entry points | 5 permissionless | 0 role-gated | 10 admin-only
> Spec: `.claude/HDCL-vault-specification.md` v0.1

---

## Protocol Flow Paths

### Setup (Admin)

`initialize()` → `setOracle()` → `setTvlCap()` → `setMinReinvestAmount()`
                                                   └─→ seed initial deposit (per spec §9)

### User Deposit Flow

`[admin setup above]` → `User.deposit(hollarAmount)` → `DecentralPool.deposit()` → NFT position created
                                                      └─→ HDCL minted to user

### User Redemption Flow

`[deposit above]` → `User.requestRedeem(hdclAmount)` → HDCL escrowed (per spec: NOT burned, stays in totalSupply)
                                                       ├─→ `User.cancelRedeem(requestId)` → HDCL returned
                                                       └─→ `pokeQueue()` → HOLLAR transferred to user  ◄── requires idleHollar

### Position Lifecycle (Keeper)

`[deposit above]` → [60 days maturity] → `pokeDecentral(i)` Active→YWR
                                         → `pokeDecentral(i)` YWR→YC  ◄── requires Decentral approval (48h SLA per spec)
                                         → `pokeDecentral(i)` YC→PWR
                                         → `pokeDecentral(i)` PWR→Redeemed  ◄── requires approval + 48h delay
                                         └─→ idleHollar increased → auto-processes queue

### Reinvestment (Keeper)

`[position redeemed, queue can't progress]` → [idleHollar >= minReinvestAmount] → `pokeQueue()` → `_reinvest()`
Note: spec §4.7 requires `totalQueuedHdcl == 0`; code reinvests when queue can't progress (spec deviation #2)

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
| Spec ref | §4.2 — matches spec except: queue NOT processed during deposit (per spec §4.2: "The redemption queue is NOT processed during deposits") ✓ |

### `HDCLVault.requestRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | User |
| Parameters | `hdclAmount` (user-controlled) |
| Call chain | `→ _transfer(user, vault, hdclAmount) → redemptionQueue[queueTail] = new request → queueTail++ → totalQueuedHdcl += hdclAmount` |
| State modified | `redemptionQueue[]`, `queueTail`, `totalQueuedHdcl`, ERC-20 balances (HDCL escrowed) |
| Value flow | Tokens: user → Vault (HDCL escrow) |
| Reentrancy guard | yes |
| Spec ref | §4.6 — code adds `minRedeemAmount` guard not in spec. Code uses mapping+head/tail vs spec's array+active field (spec deviation #9) |

### `HDCLVault.cancelRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**no** whenNotPaused — allows cancellation during pause) |
| Caller | Original request owner (verified via `request.user != msg.sender` check) |
| Parameters | `requestId` (user-controlled) |
| Call chain | `→ totalQueuedHdcl -= remaining → _transfer(vault, user, remaining) → delete redemptionQueue[requestId]` |
| State modified | `redemptionQueue[requestId]` (deleted), `totalQueuedHdcl`, ERC-20 balances |
| Value flow | Tokens: Vault → user (HDCL returned from escrow) |
| Reentrancy guard | yes |
| Spec ref | §4.6 — spec uses `active = false`, code uses `delete` (mapping pattern). No pause guard is intentional — users can always exit queue |

### `HDCLVault.pokeDecentral()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Anyone (keeper bot expected, per spec §5) |
| Parameters | `positionIndex` (user-controlled) |
| Call chain | `→ DecentralPool.requestYieldWithdrawal() → DecentralPool.executeYieldWithdrawal() → _adjustBucketOnYieldClaim() → DecentralPool.requestPrincipalWithdrawal() → DecentralPool.executePrincipalWithdrawal() → _adjustBucketOnPrincipalRedemption() → _advancePositionHead() → _processQueueWithHollar()` |
| State modified | `positions[i].state`, `apyBuckets[]`, `yieldRateSum`, `yieldOffsetSum`, `totalInvestedPrincipal`, `idleHollar`, `totalStaleValue`, `positionHead`, `redemptionQueue[]`, `queueHead`, `totalQueuedHdcl`, ERC-20 balances |
| Value flow | Tokens: DecentralPool → Vault (yield + principal) → possibly Vault → queue users (HOLLAR) |
| Reentrancy guard | yes |
| Spec ref | §4.5 — spec names this `processPosition()`. Code renames to `pokeDecentral()`. Also handles stale position accounting (spec §4.5 D15) |

### `HDCLVault.pokeQueue()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Anyone (keeper bot expected) |
| Parameters | none |
| Call chain | `→ _processQueueWithHollar(idleHollar, rate) → [if queue can't progress] _reinvest() → DecentralPool.deposit()` |
| State modified | `redemptionQueue[]`, `queueHead`, `totalQueuedHdcl`, `idleHollar`, `positions[]`, `apyBuckets[]`, `totalInvestedPrincipal`, `yieldRateSum`, `yieldOffsetSum`, ERC-20 balances |
| Value flow | Tokens: Vault → queue users (HOLLAR fulfillment) or Vault → DecentralPool (reinvestment) |
| Reentrancy guard | yes |
| Spec ref | §4.6 + §4.7 — spec has separate `processQueue()` and `reinvest()`. Code merges into `pokeQueue()`. Reinvest condition differs: spec requires `totalQueuedHdcl == 0`, code allows when queue can't make progress (spec deviation #2) |

---

## Admin-Only

All gated by `onlyRole(ADMIN_ROLE)`. (Per spec §4.8): controlled by single governance EOA.

| Contract | Function | Parameters | State Modified | Spec Ref |
|----------|----------|------------|----------------|----------|
| HDCLVault | `pauseDeposits()` | none | `depositsPaused = true` | §4.8 ✓ |
| HDCLVault | `unpauseDeposits()` | none | `depositsPaused = false` | §4.8 ✓ |
| HDCLVault | `pause()` | none | PausableUpgradeable paused state | §4.8 ✓ |
| HDCLVault | `unpause()` | none | PausableUpgradeable unpaused state | §4.8 ✓ |
| HDCLVault | `setTvlCap(uint256)` | `newCap`; requires `>= totalAssets()` | `tvlCap` | §4.8 — spec allows decrease, code doesn't (deviation #5) |
| HDCLVault | `setMinReinvestAmount(uint256)` | `amount` | `minReinvestAmount` | §4.8 ✓ |
| HDCLVault | `setMinRedeemAmount(uint256)` | `amount` | `minRedeemAmount` | Not in spec (deviation #7) |
| HDCLVault | `setOracle(address)` | `_oracle`; zero-check | `oracle` | Not in spec (deviation #8) |
| HDCLVault | `markPositionStale(uint256)` | `positionIndex` | stale accounting, `totalStaleValue` | §4.5 — missing withdrawal-delay guard (deviation #3) |
| HDCLVault | `unmarkPositionStale(uint256)` | `positionIndex` | reverse stale accounting, reset `yieldStartTime` | §4.8 ✓ |

---

## Initialization

### `HDCLVault.initialize()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, initializer |
| Caller | Deployer (one-time) |
| Parameters | `_decentralPool`, `_poolToken`, `_hollar`, `_tvlCap`, `_admin` — all deployer-provided, zero-address validated |
| Call chain | `→ __ERC20_init("Hydrated Decentral", "HDCL") → __AccessControl_init → __UUPSUpgradeable_init → __Pausable_init → __ReentrancyGuard_init → _grantRole(DEFAULT_ADMIN_ROLE, admin) → _grantRole(ADMIN_ROLE, admin) → _grantRole(UPGRADER_ROLE, admin)` |
| State modified | All initializable state |
| Spec ref | §9 — spec mentions "Seed initial deposit to establish the 1:1 exchange rate and avoid first-depositor attack" as Phase 2 post-deployment step |
