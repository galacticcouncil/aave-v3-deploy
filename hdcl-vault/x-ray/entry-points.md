# Entry Point Map

> HDCL Vault | `feat/hdcl-vault` @ `9d49425` | ERC-4626 + ERC-7540 (async-redeem)
> 30+ entry points: 11 permissionless · 2 role-gated (claim) · ~12 admin-only

---

## Protocol Flow Paths

### Setup (Admin)

```
initialize(pool, nft, hollar, tvlCap, admin)
  └─ registers `pool` and sets it as activeDepositPool in one shot
     └─ grants DEFAULT_ADMIN_ROLE + ADMIN_ROLE + UPGRADER_ROLE to admin
```

Post-init (admin, in any order):
- `grantRole(GUARDIAN_ROLE, techCommittee)` — needed for fast pause/unpause
- `grantRole(CLAIM_OPERATOR_ROLE, keeperBot)` — needed for auto-claim
- `setOracle(oracle)` — only if external oracle consumers (Aave) are wired
- `seed initial deposit` — establishes 1:1 exchange rate
- For multi-pool deployments: `registerPool(pool2)` + optionally `setActiveDepositPool(pool2)` later

### User Deposit Flow

`User.deposit(assets, receiver)` → `DecentralPool.deposit()` on **active deposit pool** → NFT minted to vault → hDCL minted to `receiver`
- Equivalent: `User.mint(shares, receiver)` (rounds-up the HOLLAR pull)

### User Redemption Flow — pull-with-claim

```
User.requestRedeem(shares, controller, owner)
  └─ hDCL escrowed to vault (not burned)
        ├─→ User.cancelRedeem(reqId)          → hDCL refunded (unsettled portion only)
        └─→ Keeper.pokeQueue() / pokeDecentral
              └─ rate-locks HOLLAR into totalReservedHollar at fulfillment time
                    └─→ controller.redeem(shares, receiver, controller)   ◄── pull
                        OR  withdraw(assets, receiver, controller)
                        OR  delegated by isOperator / CLAIM_OPERATOR_ROLE
```

### Position Lifecycle (Keeper)

```
Keeper.pokeDecentral(positionIndex)   ── position routes through positionPool[i]
  Active             →[≥60d]→  YieldWithdrawalRequested
  YieldWithdrawalRequested  →[approve]→  YieldClaimed         (idle += yield)
  YieldClaimed       →[same call]→     PrincipalWithdrawalRequested
  PrincipalWithdrawalRequested →[approve+delay]→ Redeemed     (idle += principal)
                                                  └─ auto-runs queue settle
```

All Decentral calls wrapped in try/catch. State stays put on revert; next poke retries.

### Reinvestment

`pokeQueue()` → if queue can't progress and `idleHollar >= minReinvestAmount` → reinvest into **active deposit pool** (creating a fresh Active position)

---

## Permissionless

### ERC-4626 deposit side

| Function | Visibility | Notes |
|---|---|---|
| `deposit(assets, receiver)` | external, nonReentrant, whenNotPaused | Returns shares minted. Reverts if deposits paused or TVL exceeded. Routes to `activeDepositPool`. |
| `mint(shares, receiver)`    | external, nonReentrant, whenNotPaused | Same path; computes `assets = previewMint(shares)` (rounds up). |

### ERC-7540 async redeem flow

| Function | Visibility | Notes |
|---|---|---|
| `requestRedeem(shares, controller, owner)` | external, nonReentrant, whenNotPaused | `msg.sender == owner` OR `isOperator[owner][msg.sender]`. Escrows hDCL; appends to `redemptionQueue`. |
| `cancelRedeem(requestId)` | external, nonReentrant (**no** whenNotPaused) | Only refunds the **unsettled** portion; settled hDCL stays claimable. |
| `redeem(shares, receiver, controller)` | external, nonReentrant, whenNotPaused | Pull. Auth: `msg.sender == controller` OR operator OR `CLAIM_OPERATOR_ROLE` (with `receiver == controller` + opt-in). Burns escrowed hDCL, transfers HOLLAR from `totalReservedHollar`. |
| `withdraw(assets, receiver, controller)` | external, nonReentrant, whenNotPaused | Same as `redeem` but specified in HOLLAR. |

### Operator + auto-claim opt-in (user)

| Function | Notes |
|---|---|
| `setOperator(operator, approved)` | Per-spec ERC-7540 operator approval. |
| `setAutoClaim(enabled)` | Opts the caller in/out of `CLAIM_OPERATOR_ROLE` auto-claim. |

### Keeper hooks

| Function | Notes |
|---|---|
| `pokeDecentral(positionIndex)` | Drives the position state machine via `positionPool[i]`. Try/catch around every Decentral call; the rest of the cycle isolates from a paused/broken pool. |
| `pokeQueue()` | Settles queue at current `exchangeRate()`. If unable to progress and idle ≥ minReinvest, calls `_reinvest` into the active deposit pool. |

---

## Role-Gated (claim path only)

| Role | What it can do |
|---|---|
| `CLAIM_OPERATOR_ROLE` | Call `redeem`/`withdraw` on behalf of a controller **only if** that controller has `autoClaimEnabled == true` **and** `receiver == controller`. Role grants *timing* of the claim, not the *destination*. |

---

## Admin / Guardian

| Function | Role | Notes |
|---|---|---|
| `pauseDeposits()` / `unpauseDeposits()` | ADMIN or GUARDIAN | Toggles deposit-only pause (queue/claim still works). |
| `pause()` / `unpause()`                 | ADMIN or GUARDIAN | Full `whenNotPaused` halt. |
| `setTvlCap(newCap)`        | ADMIN | Global cap across all pools; requires `newCap >= totalAssets()`. |
| `setMinReinvestAmount(x)`  | ADMIN | |
| `setMinRedeemAmount(x)`    | ADMIN | |
| `setOracle(addr)`          | ADMIN | Zero-check. Used by WDCLOracle consumers. |
| `registerPool(pool)`       | ADMIN | Adds a Decentral pool to the registry. |
| `setActiveDepositPool(pool)` | ADMIN | Routes **new** deposits + reinvest to `pool`. Must be registered. Existing positions anchor to `positionPool[i]`. |
| `retirePool(pool)`         | ADMIN | Removes a pool from the registry. Requires zero open positions in that pool. |

`DEFAULT_ADMIN_ROLE` grants/revokes all roles. `UPGRADER_ROLE` authorizes UUPS upgrades.

**Trust model (per `PLAN-multi-pool.md`):**
- ADMIN ≈ Hydration governance *economics-parameters* track
- GUARDIAN ≈ Hydration *technical committee* (anything ADMIN can do on pause, GUARDIAN can do too)

---

## Initialization

### `initialize(_decentralPool, _poolToken, _hollar, _tvlCap, _admin)`

| Aspect | Detail |
|--------|--------|
| Visibility | external, initializer |
| Zero-checks | All addresses |
| Effects | Registers `_decentralPool` and sets it as `activeDepositPool` (one-shot — no separate `registerPool` / `setActiveDepositPool` calls needed at deploy); sets `tvlCap`; defaults `minReinvestAmount = 10e18`, `minRedeemAmount = 1e18`; grants `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `UPGRADER_ROLE` to `_admin`. |
| Not granted at init | `GUARDIAN_ROLE`, `CLAIM_OPERATOR_ROLE` — admin grants these post-init to the appropriate addresses. |
| Notes | No `withdrawalDelay` parameter (removed). Multi-pool flow uses `registerPool` post-init for *additional* pools. |

---

## ERC-7540 conformance views

| Function | Purpose |
|---|---|
| `pendingRedeemRequest(reqId, controller)` | Unsettled shares for this request, owned by `controller`. |
| `claimableRedeemRequest(reqId, controller)` | Settled-but-unclaimed shares for this request. |
| `supportsInterface(bytes4)` | Declares ERC-165, ERC-4626, ERC-7540 Operator, ERC-7540 Redeem. |
