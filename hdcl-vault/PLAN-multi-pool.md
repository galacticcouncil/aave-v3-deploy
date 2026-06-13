# PLAN — Multi-Pool Support (Option A: admin-only routing)

## Goal

Make BIL a long-running yield-bearing vault that persists across Decentral pool rotations. Users hold one fungible hDCL token; new deposits route to whichever DecentralPool the admin has set as active. Old positions wind down in their original pool via the existing keeper lifecycle.

## Trust model

Three on-chain roles with distinct authorities and cadences:

| Role | Substrate path | Authority | Cadence |
|------|---------------|-----------|---------|
| `ADMIN_ROLE` | Hydration governance, **economics-params track** | Everything | Days (propose → vote → execute) |
| `GUARDIAN_ROLE` | **Technical committee** | Pause/unpause both `pauseDeposits`/`unpauseDeposits` and `pause`/`unpause` | Fast (committee signature) |
| `CLAIM_OPERATOR_ROLE` | **Keeper bot(s)** | Call `redeem`/`withdraw` on behalf of opted-in controllers; constrained so HOLLAR can only go to the controller's own address (no redirect) | On-demand, per-request |

**Admin ⊇ Guardian principle.** Anything the guardian can do, the admin can also do. Implementation pattern: a single `onlyAdminOrGuardian` modifier guards pause/unpause functions; both roles satisfy it. The admin role does NOT need to also hold the guardian role.

**Symmetric pause/unpause for the guardian.** The technical committee can both halt and resume — for both `pauseDeposits` and full `pause`. Rationale: if the committee can react fast enough to stop a problem, they should also be able to release the brake once they've verified things are safe again, without waiting for the multi-day governance cycle. Forcing every unpause through slow governance would create a denial-of-service incentive (a single bad-faith pause locks the vault for days).

**Rotation cadence.** Routine pool rotations (register, switch, retire) ride the slow `ADMIN_ROLE` track. Emergency halts and resumptions ride the fast `GUARDIAN_ROLE` track. The fast path closes the window where a deteriorating Decentral pool could keep accepting deposits during the multi-day proposal cycle for rotation.

`ADMIN_ROLE` exclusively retains all other operations: `registerPool`, `setActiveDepositPool`, `retirePool`, `setTvlCap`, `setOracle`, `setMinRedeemAmount`, `setMinReinvestAmount`, plus UUPS upgrade authorization via `UPGRADER_ROLE`.

`CLAIM_OPERATOR_ROLE` is the auto-claim authority. Compared to a per-user 7540 operator approval (which still works alongside), this role is:
- Granted by admin once, at deploy or via governance (typically to a keeper bot address)
- Gated on a per-controller `autoClaimEnabled` flag — the controller must opt in before the role-holder can act on their behalf
- Strictly constrained: the role-holder can call `redeem`/`withdraw` for an opted-in controller, but `receiver` is forced to equal `controller`. The role provides timing, not redirect authority.

Protocol-owned positions (treasury, integration wrappers) opt themselves in by calling `setAutoClaim(true)` from their own contract logic — same path as a regular user. There is no admin override for the opt-in flag.

## Design — Option A: admin-only routing

`activeDepositPool` is a single admin-set field. New deposits and reinvestments route there. Registered-but-not-active pools continue processing their existing positions via `pokeDecentral`. No automatic fallback, no deposit queue.

## State changes

Replace:
```solidity
IDecentralPool public decentralPool;
IPoolToken    public poolToken;
```

With:
```solidity
IDecentralPool[]                       public pools;              // registry, ordered by registration
mapping(IDecentralPool => bool)        public isPoolRegistered;
mapping(address => bool)               public isRegisteredPoolToken; // for onERC721Received
IDecentralPool                         public activeDepositPool;  // where new deposits land
```

Add to `NFTPosition`:
```solidity
IDecentralPool pool; // which pool minted this position
```

The position's `apyWad` is still snapshotted at deposit (one SLOAD vs. an external call later). `pool` is the new field that tells `pokeDecentral` which contract to drive.

## New admin functions

```solidity
function registerPool(IDecentralPool newPool) external onlyRole(ADMIN_ROLE);
// - Reverts if already registered
// - Verifies newPool.stablecoin() == hollar
// - Reads pool.poolToken() and adds it to isRegisteredPoolToken
// - If pools.length == 0, sets activeDepositPool = newPool

function setActiveDepositPool(IDecentralPool pool) external onlyRole(ADMIN_ROLE);
// - Reverts if pool not registered
// - Sets activeDepositPool = pool

function retirePool(IDecentralPool pool) external onlyRole(ADMIN_ROLE);
// - Reverts if pool == activeDepositPool (must switch first)
// - Reverts if any open position still references this pool
//   (iterate positions[positionHead..length) and check pos.pool != pool || pos.state == Redeemed)
// - Removes from registry and isRegisteredPoolToken
```

`retirePool` requires zero open positions. No retire-while-open path — keeps the invariant that every registered pool is reachable by the keeper lifecycle, and avoids orphan-pool state.

### Role updates on existing functions

All four pause/unpause functions move from `onlyRole(ADMIN_ROLE)` to `onlyAdminOrGuardian`:

```solidity
modifier onlyAdminOrGuardian() {
    require(
        hasRole(ADMIN_ROLE, msg.sender) || hasRole(GUARDIAN_ROLE, msg.sender),
        "Not admin or guardian"
    );
    _;
}
```

Affected: `pauseDeposits`, `unpauseDeposits`, `pause`, `unpause`. The `Admin ⊇ Guardian` principle means admin still has full authority — no functions are guardian-only.

## Lifecycle plumbing

- `_depositIntoDecentral(amount)`: read `activeDepositPool`, snapshot its APY into `pos.apyWad` and its address into `pos.pool`. Approval flow targets the active pool.
- `pokeDecentral(positionIndex)`: every `decentralPool.*` call becomes `pos.pool.*`. The state machine is unchanged.
- `onERC721Received`: check `isRegisteredPoolToken[msg.sender]` instead of `msg.sender == address(poolToken)`.
- `getAPYWad()`: returns `activeDepositPool.fixedAPYWad()` — the APY a new deposit would receive. The vault's blended APY across all pools is observable only via `exchangeRate()` movement; we won't expose a synthetic-blended view.
- `_investmentPeriod()`, `_decentralWithdrawalDelay()`: take a pool argument or read from `pos.pool` at call sites.

## Pool rotation procedure

### Normal rotation (slow path only)

A pre-planned rotation when Decentral deploys Pool B to replace Pool A:

```
T0: Decentral announces + deploys Pool B
T1: Governance proposal (economics-params): registerPool(B) + pauseDeposits() (batched)
T2: Vote + execute → B registered, deposits paused
    [in-flight: old A positions continue to wind down via pokeDecentral; new deposits revert cleanly]
T3: Governance proposal: setActiveDepositPool(B) + unpauseDeposits()
T4: Vote + execute → new deposits flow to B
T5 (months later, once A drains): retirePool(A)
```

### Emergency rotation (guardian-driven, governance follows)

When Decentral signals an unscheduled deprecation or starts misbehaving:

```
T0: Decentral issue detected
T1: Tech committee: pauseDeposits()     ← fast, minutes
    [deposits halt; pokeDecentral continues to wind down existing A-positions]
T2: Governance proposal: registerPool(B) + setActiveDepositPool(B)
T3: Vote + execute → B registered, B active
T4: Tech committee: unpauseDeposits()   ← fast, minutes — guardian can resume too
T5 (months later, once A drains): retirePool(A)
```

The guardian can resume deposits on the fast path once the new pool is in place. No need to wait for a separate governance cycle just to unpause.

### Full emergency halt (worst case)

If Decentral is misbehaving badly enough that redemptions and keeper progression must also stop (e.g., suspected exploit affecting yield/principal payouts):

```
T0: Severe incident detected
T1: Tech committee: pause()    ← full halt: blocks deposit, requestRedeem, pokeDecentral, pokeQueue
    [vault is frozen except for cancelRedeem, which intentionally stays callable]
T2: Investigation and remediation. Governance may upgrade impl if needed.
T3: Tech committee (or admin): unpause() once safe
T4: Vault resumes
```

The guardian's ability to unpause is what makes this useful. If only admin could unpause, every fast halt would translate to a multi-day vault freeze even after the incident was cleared — turning a safety mechanism into a denial-of-service vector.

## Failure modes under Option A

| Scenario | Behavior |
|----------|----------|
| `activeDepositPool` refuses a deposit (paused, max-TVL, shutdown) | `vault.deposit()` reverts. User keeps HOLLAR. They retry after governance updates the active pool. |
| `activeDepositPool` refuses inside `_reinvest()` | `pokeQueue` reverts. Mitigation: governance pre-emptively sets `depositsPaused = true` so `pokeQueue` skips the reinvest leg. Idle HOLLAR sits unused until the new pool is active. |
| Old pool stops paying yield/principal mid-lifecycle | Handled today — `pokeDecentral` try/catches every Decentral call. Position sits in its current state until pool recovers. |
| Old pool fully dies | UUPS upgrade path to add a write-down function. Same as current single-pool failure mode. |

## ERC-7540 + ERC-4626 conformance

BIL is a yield-bearing vault with async redemption. The natural standards are **ERC-4626** (base tokenized vault interface) and **ERC-7540** (async tokenized vault extension). Conformance unlocks integration with vault-aware tooling (Aave 3 collateral wrappers, Morpho strategies, Yearn aggregators, indexer support, audited router contracts) and is now in scope.

### Surface to add

**ERC-4626 base (synchronous deposit side):**
- `asset()` → returns HOLLAR address
- `convertToShares(uint256 assets)` / `convertToAssets(uint256 shares)`
- `maxDeposit(address)` / `maxMint(address)` — gate on `tvlCap` minus current `totalAssets()`
- `maxWithdraw` / `maxRedeem` → return 0 (sync withdraw not supported; async only)
- `previewDeposit` ✓ (already exists)
- `previewMint(uint256 shares)`
- `previewWithdraw` / `previewRedeem` ✓ (already exists with one)
- Standard `Deposit` event with the canonical 4-param signature

Change `deposit(uint256)` signature to ERC-4626: `deposit(uint256 assets, address receiver)`. Existing tests call the 1-arg form — needs migration. Add `mint(uint256 shares, address receiver)` as well.

**ERC-7540 async redemption:**
- `requestRedeem(uint256 shares, address controller, address owner)` → returns `uint256 requestId`
  - Current `requestRedeem(uint256 bilAmount)` needs the extra params.
  - `owner` must approve `msg.sender` to spend shares (or be `msg.sender`).
  - `controller` is who can manage and claim the request (often == owner).
- `pendingRedeemRequest(uint256 requestId, address controller)` view — shares still in queue
- `claimableRedeemRequest(uint256 requestId, address controller)` view — shares processed and ready to claim
- `withdraw(uint256 assets, address receiver, address controller)` → claim assets
- `redeem(uint256 shares, address receiver, address controller)` → claim by share amount
- Operator pattern: `setOperator(address operator, bool approved)`, `isOperator(address controller, address operator)`
- Canonical events: `RedeemRequest(controller, owner, requestId, sender, shares)`, `Deposit(sender, owner, assets, shares)`, `OperatorSet(controller, operator, approved)`

**ERC-165 interface declarations:**
- `supportsInterface` returns true for `type(IERC7540).interfaceId`, `type(IERC4626).interfaceId`, `type(IERC165).interfaceId`

### Settlement model: pull at the contract layer, delegated claim at the UX layer

The current vault is **push-based**: when `pokeQueue` processes a request, HOLLAR is transferred directly to the user in the same call. The user never claims. This is operationally smooth but non-conformant — `claimableRedeemRequest` would always be 0 because requests skip the claimable state.

ERC-7540 expects **pull-based** redemption: requests transition `pending → claimable → claimed`, and `claimed` is a user (or operator) call to `redeem` / `withdraw`.

**Decision: pull at the contract layer.** `pokeQueue` rate-locks each request and moves HOLLAR from `idleHollar` into `totalReservedHollar`; no transfer, no burn. All HOLLAR egress happens through `redeem` / `withdraw` against the rate-locked state. This makes 7540 conformance real, not partial — the lifecycle, view functions, and auth checks all behave per spec.

**One-tx UX is restored at a layer above** via two opt-in delegation primitives:

1. **`CLAIM_OPERATOR_ROLE` + per-controller `autoClaimEnabled` flag** — see the next section. Users who opt in have their claims auto-executed by the keeper bot; HOLLAR can only land at the controller's own address.
2. **Standard 7540 `setOperator`** — users can approve any address (e.g., an Aave market integration) as their per-user operator. The operator can claim and redirect to arbitrary `receiver` addresses, by the user's choice.

Net behavior across the three user populations:

| User chose | User tx count | Effective feel |
|------------|--------------|----------------|
| `setAutoClaim(true)` | 1 (`requestRedeem` only) | Push |
| `setOperator(integrator, true)` | 1 (`requestRedeem` only) | Push, via standard 7540 operator |
| Neither (default) | 2 (`requestRedeem` + `redeem`) | Pure pull |

So this is technically pull (single-path settlement in the contract) and operationally hybrid (push-feel for users who opt in). The earlier framing of "Pull vs. Hybrid" as competing options was misleading — the design we landed on is **pull-with-delegated-claim**, which dominates both:

- vs. **Push:** conformant lifecycle, no `claimable`-is-always-0 weirdness, no auth-bypass risk from a contract that auto-pays
- vs. **plain Pull:** auto-claim path for opted-in users restores one-tx UX without contract-side double-pathing
- vs. **classic Hybrid (push-by-default + optional claim):** no sometimes-push-sometimes-not branching in `pokeQueue`; no accounting fork; auto-claim is a separate primitive that any user can decline

The original push-based design's "UX optimization" survives — just relocated from inside `pokeQueue` into an opt-in role + operator pattern at the auth layer.

### Rate-lock semantics under pull

Today, `pokeQueue` computes `rate = exchangeRate()` once per call, then settles each entry at that rate. Under pull:
- When processing a request, lock the rate by recording `(bilConsumed, hollarOwed)` on the request struct.
- `claimableRedeemRequest` returns `bilConsumed` (or equivalent assets via the locked rate).
- `redeem(shares, receiver, controller)` pays `hollarOwed` for the locked shares; burns the hDCL from escrow.
- Partial fulfillment naturally extends: a request can have multiple `(bil, hollar)` lock entries.

The shift moves HOLLAR-out from `pokeQueue` to `redeem`. The pendingYield/pendingPrincipal flow into `idleHollar` unchanged.

Concrete struct + state changes:

```solidity
struct RedemptionRequest {
    address user;
    uint256 bilAmount;     // total hDCL queued
    uint256 bilSettled;    // rate-locked, ready to claim
    uint256 hollarOwed;     // HOLLAR reserved for this request, ready to claim
}

uint256 public totalReservedHollar;  // sum of hollarOwed across all requests
```

`pokeQueue` decrements `idleHollar` by the reserved amount and increments `totalReservedHollar`. The HOLLAR stays in the vault contract (token-wise) until `redeem` transfers it out. `totalAssets()` formula extends to include `totalReservedHollar` — the reserved HOLLAR still backs hDCL supply until claim:

```
totalAssets = totalInvestedPrincipal + accruedYield + idleHollar + totalPendingYield + totalReservedHollar
```

### Auto-claim via CLAIM_OPERATOR_ROLE

To preserve a one-tx UX for users while staying on the pull side of 7540, the vault adds an auto-claim authority anchored on opt-in:

```solidity
bytes32 public constant CLAIM_OPERATOR_ROLE = keccak256("CLAIM_OPERATOR_ROLE");

/// @notice Per-controller flag: if true, CLAIM_OPERATOR_ROLE holders may
///         call redeem/withdraw on the controller's behalf, paying out
///         only to the controller's own address.
mapping(address => bool) public autoClaimEnabled;

event AutoClaimSet(address indexed controller, bool enabled);

/// @notice Toggle auto-claim for msg.sender. Users opt in for themselves;
///         protocol contracts call this from their own logic.
function setAutoClaim(bool enabled) external {
    autoClaimEnabled[msg.sender] = enabled;
    emit AutoClaimSet(msg.sender, enabled);
}
```

Authorization extension on the redeem/withdraw entry points:

```solidity
function redeem(uint256 shares, address receiver, address controller)
    external
    returns (uint256 assets)
{
    if (msg.sender != controller && !isOperator[controller][msg.sender]) {
        // Role-based auto-claim path
        require(
            hasRole(CLAIM_OPERATOR_ROLE, msg.sender)
                && autoClaimEnabled[controller]
                && receiver == controller,
            "Not authorized"
        );
    }
    // ... claim logic
}
```

The `receiver == controller` constraint is load-bearing. The auto-claimer can move HOLLAR through to the user's wallet but cannot redirect it elsewhere. Compromise of a CLAIM_OPERATOR_ROLE key yields only a denial-of-control over claim *timing*, never a path to theft.

Standard 7540 paths (`msg.sender == controller`, or per-user `isOperator`) keep working unchanged — the role is supplementary. Strict 7540 conformance tests pass.

**Operational flow:**
1. Admin grants `CLAIM_OPERATOR_ROLE` to the keeper bot at deploy.
2. User opts in via `setAutoClaim(true)` (one tx, gas paid by user).
3. Protocol-owned positions call `setAutoClaim(true)` from their own contract logic.
4. After every `pokeQueue` run, keeper bot walks newly-settled requests; for each request whose `user` has `autoClaimEnabled == true`, keeper calls `redeem(r.bilSettled, r.user, r.user)`. HOLLAR lands in the user's wallet.
5. Users who haven't opted in self-claim by calling `redeem` directly.
6. Anyone can opt back out by calling `setAutoClaim(false)`.

### What stays the same

- The position lifecycle, multi-pool routing, yield math, and tvlCap behavior are all orthogonal to 7540.
- Cancellation (`cancelRedeem`) stays; ERC-7540 doesn't mandate cancel, but it's compatible.
- The slippage features are gone and stay gone.

### Test surface added

- ERC-165 detection for both interface IDs
- Operator approve + delegated claim
- Pull-based claim flow (request → wait → claim)
- `pendingRedeemRequest` and `claimableRedeemRequest` view correctness across the lifecycle
- ERC-4626 spec tests (a16z's `erc4626-tests` suite — pick the bits that apply to a partially-conformant async vault)

## Out of scope for this plan (deferred)

- **Auto-failover across registered pools** (Option B in the prior discussion). Adds a try/catch loop in `_depositIntoDecentral` to skip pools that revert. Worth revisiting after we have data on governance response time.
- **Deposit queueing** (Option C). Overkill for the failure mode.
- **Per-pool TVL cap**. Currently `tvlCap` is global across all pools. Could be split per pool later if Decentral pools have different size limits.

## Decisions locked in

| # | Decision | Choice |
|---|----------|--------|
| 1 | On-chain role split | Add `GUARDIAN_ROLE`. Distinct from `ADMIN_ROLE`. |
| 2 | Guardian authority | Symmetric pause/unpause on both `pauseDeposits/unpauseDeposits` and `pause/unpause`. |
| 3 | Admin/guardian relationship | Admin ⊇ Guardian. Anything guardian can do, admin can do. |
| 4 | Routing policy | Admin picks `activeDepositPool`. No user-pick at deposit time. |
| 5 | `tvlCap` scope | Global across all pools. |
| 6 | `retirePool` strictness | Requires zero open positions in the pool. |
| 7 | Standards conformance | Target ERC-7540 (async vault) + ERC-4626 base. See section below. |
| 8 | Redemption settlement | Pull. `pokeQueue` rate-locks; users (or `CLAIM_OPERATOR_ROLE` holders for opted-in controllers) claim via `redeem`/`withdraw`. |
| 9 | Auto-claim role | Add `CLAIM_OPERATOR_ROLE`. Per-controller `autoClaimEnabled` flag, user-toggled only (no admin override). Role-holder bound to `receiver == controller`. |

## Implementation order (when greenlit)

> **Status (2026-05-19, `9d49425`):** Workstreams 0, 1, 2 are all **landed and merged on `feat/bil-vault`**. 344 / 344 tests passing, 99.20% line coverage on `BILVault.sol`. Heterogeneous-APY tests cover 18% / 22% / 16% (incl. rate-cut scenario). 15 invariants × 12,800 fuzz calls each. See `x-ray/x-ray.md` for the current state.

Three workstreams in dependency order. Land each as a separate commit (or PR) to keep the diff reviewable.

### Workstream 0 — Prerequisite cleanup &nbsp; [DONE]

0a. **Tier 2 bucket-abstraction removal.** Drop `APYBucket`, `apyBuckets`, `activeAPYList`, `isActiveAPY`, `_addToActiveAPYsIfNew`, `_removeFromActiveAPYs`, `getActiveAPYCount`, `getActiveAPY`. Collapse `_addPrincipalToBucket` / `_removePrincipalFromBucket` to direct `totalInvestedPrincipal` updates. Math stays identical; the global aggregates `yieldRateSum` and `yieldOffsetSum` already do the work.

### Workstream 1 — Guardian role + multi-pool &nbsp; [DONE]

1. Define `GUARDIAN_ROLE` constant and `onlyAdminOrGuardian` modifier. Move `pauseDeposits`, `unpauseDeposits`, `pause`, `unpause` to `onlyAdminOrGuardian`. Grant `GUARDIAN_ROLE` to the technical committee address at deploy time.
2. Add registry state (`pools[]`, `isPoolRegistered`, `isRegisteredPoolToken`, `activeDepositPool`) + `registerPool` / `setActiveDepositPool` / `retirePool` admin functions.
3. Add `pool` field to `NFTPosition`; thread `pos.pool` through `pokeDecentral`, `_depositIntoDecentral`, `_reinvest`.
4. Update `onERC721Received` to check `isRegisteredPoolToken[msg.sender]`.
5. Update `getAPYWad()` to return `activeDepositPool.fixedAPYWad()`; update `_investmentPeriod()` and `_decentralWithdrawalDelay()` to take a pool argument or read from `pos.pool` at call sites.
6. Migration path for existing single-pool deployments: `initialize` signature stays (one pool registered at init), `registerPool` can add more later. Existing deployments don't break.
7. Tests:
   - Pool rotation full sequence
   - Emergency rotation via guardian (`GUARDIAN_ROLE.pauseDeposits` and `unpauseDeposits` on the fast path)
   - `GUARDIAN_ROLE.pause()` + `GUARDIAN_ROLE.unpause()` round-trip
   - Both ADMIN and GUARDIAN can call all four pause/unpause functions; non-role addresses revert
   - `retirePool(activeDepositPool)` reverts
   - `retirePool(poolWithOpenPositions)` reverts
   - Deposits during pauseDeposits revert cleanly
   - Reinvest skipped while `depositsPaused == true`
   - Heterogeneous-APY accrual: positions across two pools at different APYs produce correct `totalAssets()` and `exchangeRate()`

### Workstream 2 — ERC-7540 + ERC-4626 conformance &nbsp; [DONE — split into W2a..W2d]

8. Add `asset()`, `convertToShares`, `convertToAssets`, `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`, `previewMint`.
9. Change `deposit(uint256)` → `deposit(uint256 assets, address receiver)`; add `mint(uint256 shares, address receiver)`. Emit canonical `Deposit(sender, owner, assets, shares)` event.
10. Change `requestRedeem(uint256)` → `requestRedeem(uint256 shares, address controller, address owner)`. Implement owner-allowance check.
11. **Switch redemption from push to pull.** Modify `_processQueueWithHollar` to record `bilSettled` / `hollarOwed` on each request and move HOLLAR from `idleHollar` into `totalReservedHollar` instead of pushing. Update `totalAssets()` to include `totalReservedHollar`. Implement `redeem(shares, receiver, controller)` and `withdraw(assets, receiver, controller)` for users to claim.
12. Add operator pattern: `setOperator(address, bool)`, `isOperator(address, address)`, `OperatorSet` event. Permit operator-initiated `requestRedeem`, `redeem`, `withdraw`.
13. Add `CLAIM_OPERATOR_ROLE` + `autoClaimEnabled` mapping + `setAutoClaim(bool)` function. Extend `redeem`/`withdraw` auth check with the role-based path (constrained to `receiver == controller`).
14. Add view functions: `pendingRedeemRequest(requestId, controller)`, `claimableRedeemRequest(requestId, controller)`.
15. Add ERC-165 `supportsInterface` returning true for ERC-7540, ERC-4626, ERC-165 interface IDs.
16. Tests:
   - ERC-165 detection for both interface IDs
   - ERC-4626 sync deposit path with receiver != sender
   - Operator approval + delegated claim flow
   - Pull-based redemption: request → process → claim
   - `pendingRedeemRequest` and `claimableRedeemRequest` correctness across the lifecycle, including partial fulfillment
   - `CLAIM_OPERATOR_ROLE`: opted-in controller can be auto-claimed by role-holder; non-opted-in reverts; role-holder cannot redirect (receiver != controller reverts); user can opt out and subsequent attempts revert
   - ERC-4626 spec tests (a16z `erc4626-tests` subset that applies to async vaults)
   - Migration: existing pre-7540 callers (if any) get a clear revert with the new signatures, not silent acceptance

## Related cleanup that should land first

Already absorbed into Workstream 0 above. Listed separately here as a reminder: the bucket-abstraction removal is independent of both multi-pool and 7540, and should be the first commit so subsequent diffs are clean.
