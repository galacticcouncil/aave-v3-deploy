# Spec-Conformance Fixes (#4, #17, #13)

> Status: **[DONE]** — landed in `41037fc` on `feat/hdcl-vault`. 350/350 tests pass; vault bytecode 24,540 B (36 B buffer under EIP-170 at `optimizer_runs=30`).
>
> Branch: `feat/hdcl-vault`
> Target: three findings from the audit pass — two ERC-4626/7540 conformance, one mid-severity DoS amplifier on multi-pool deployments.

All three are storage-layout safe (no slot changes) so they ship as a single UUPS upgrade. Order doesn't matter; they're independent. Suggest doing them in **#13 → #4 → #17** order (cheapest mechanical change first, biggest test churn last).

---

## Fix #13 — bound `_advancePositionHead` sweep

### Problem

`_advancePositionHead` (`HDCLVault.sol:1479-1486`) is an **unbounded** `while`:

```solidity
function _advancePositionHead() internal {
    while (
        positionHead < positions.length &&
        positions[positionHead].state == NFTState.Redeemed
    ) {
        positionHead++;
    }
}
```

It's called from `pokeDecentral` after the PrincipalWithdrawalRequested → Redeemed transition (line 813). In the single-pool deployment, positions naturally redeem in order, so the loop usually advances by 1.

With **multi-pool**, positions in different pools mature at different times. A late pool with positions [10..100] can finish redeeming before an earlier pool's positions [0..9]. When position 0 eventually transitions to Redeemed, the sweep runs through 100+ `SLOAD`s of `positions[i].state` (~2100 gas each cold). With a few thousand stacked Redeemed entries, the sweep blows the block gas limit and **bricks `pokeDecentral`** until manual cleanup. Same DoS-amplifier class as the queue-tail bloat we just fixed.

### Fix

Add a per-call cap, identical pattern to `cancelRedeem`'s head sweep:

```solidity
uint256 public constant MAX_POSITION_HEAD_SWEEP = 50;

function _advancePositionHead() internal {
    uint256 head = positionHead;
    uint256 len = positions.length;
    uint256 swept;
    while (
        head < len &&
        positions[head].state == NFTState.Redeemed &&
        swept < MAX_POSITION_HEAD_SWEEP
    ) {
        unchecked { head++; swept++; }
    }
    positionHead = head;
}
```

**Why bounded sweep is sufficient (no need for a separate explicit advancer):**

`_advancePositionHead` is idempotent — running it again from the current head picks up where the previous bounded call left off, because `positionHead` is the natural cursor. Subsequent `pokeDecentral` calls (the keeper's normal cadence) drain backlog 50 at a time.

To keep `positionHead` fresh even when no position is being redeemed in the cycle, **also call `_advancePositionHead` from `pokeQueue`** — keepers call `pokeQueue` every cycle, so head stays in sync without requiring user action.

```solidity
// Inside pokeQueue, after the queue processing block (before _reinvest):
_advancePositionHead();
```

### Affected call sites

| Caller | Today | After fix |
|---|---|---|
| `pokeDecentral` (Redeemed arm) | unbounded sweep | up to 50 |
| `pokeQueue` (new call) | — | up to 50 |
| `getEstimatedWaitTime`, `retirePool` | iterate from `positionHead`; both already skip Redeemed entries via state check | unchanged — they tolerate a lagging head |

### Storage impact

None. New constant only.

### Tests

Three new tests in `test/unit/ProcessPosition.t.sol` (or a new `PositionHeadAdvance.t.sol`):

1. **`test_advancePositionHead_respectsSweepCap`** — create 60 positions, force out-of-order redemption (positions 1..60 redeem before 0), redeem position 0, assert `positionHead == 50` (not 60).
2. **`test_advancePositionHead_drainsBacklogAcrossCalls`** — same setup, subsequent `pokeQueue` advances another 50, head reaches 60.
3. **`test_pokeQueue_advancesPositionHead`** — redeem a position via pokeDecentral (no sweep beyond N=50 if there are >50 redeemed), confirm subsequent `pokeQueue` continues advancing.

For the "force out-of-order redemption" setup: spin up a second pool with shorter `minimumInvestmentPeriodSeconds`, register both, deposit to pool 1 first then pool 2, warp past pool 2's maturity (still inside pool 1's), redeem pool 2's positions via `_processPositionFull`, then warp + redeem pool 1's seed position.

### Risk

Low. Bounded sweep is the same pattern used in `cancelRedeem` head sweep (line 591-601), already test-covered. No semantic change to `positionHead` other than "may temporarily lag in extreme out-of-order scenarios."

---

## Fix #4 — `previewDeposit` reverts to match actual `deposit`

### Problem

`previewDeposit` (`HDCLVault.sol:1018-1034`) returns 0 on three conditions where the actual `deposit` reverts:

| Input | `previewDeposit` returns | `deposit` reverts with |
|---|---|---|
| `hollarAmount == 0` | 0 | `ZeroAmount` |
| First deposit, `hollarAmount <= DEAD_SHARES` | 0 | `DepositTooSmall` |
| Subsequent deposit, `totalAssets() == 0` | 0 | `VaultEmpty` |
| Subsequent deposit, rounds to zero shares | (no current handling, panics on div) | `DepositTooSmall` |

ERC-4626 §previewDeposit:

> MUST return as close to and no more than the exact amount of Vault shares that would be minted in a deposit call in the same transaction.

The "in the same transaction" wording implies preview's success/revert behavior must match `deposit`'s. An integrator polling `previewDeposit` to size a tx will ship one that unexpectedly reverts.

### ERC-4626 spec carve-outs

The spec explicitly says preview should **NOT** account for `maxDeposit` user/global limits:

> previewDeposit MUST NOT account for deposit limits like those returned from `maxDeposit` and should always act as though the deposit would be accepted, regardless if the user has enough tokens approved, etc.

So `previewDeposit` should still **ignore**:
- `depositsPaused` (a global state limit)
- `tvlCap` overflow (a global cap)
- The user's HOLLAR balance / approval (a per-user limit)

But it must **honor**:
- Math reverts (`ZeroAmount`, `DepositTooSmall`, `VaultEmpty`)

### Fix

Replace the swallow-and-return-0 conditions with reverts that exactly match `deposit`'s math path:

```solidity
function previewDeposit(uint256 hollarAmount) external view returns (uint256 hdclAmount) {
    if (hollarAmount == 0) revert ZeroAmount();
    uint256 supply = totalSupply();
    if (supply == 0) {
        if (hollarAmount <= DEAD_SHARES) revert DepositTooSmall();
        return hollarAmount - DEAD_SHARES;
    }
    uint256 assets = totalAssets();
    if (assets == 0) revert VaultEmpty();
    hdclAmount = (hollarAmount * supply) / assets;
    if (hdclAmount == 0) revert DepositTooSmall();
}
```

This is byte-for-byte the math half of `_validateAndPreviewShares` minus the `_validateDeposit` call (which checks pause + TVL cap — both excluded per spec).

### Affected callers / tests

The e2e test (`script/e2e-test.ts`) calls `previewDeposit(1000 HOLLAR)` post-seed — that path returns a positive number, no change.

Unit tests in `test/unit/PreviewDeposit.t.sol` — check what they currently assert.

| Existing test behavior | After fix |
|---|---|
| `previewDeposit(0) == 0` | must revert with `ZeroAmount` — update test |
| `previewDeposit(<=DEAD_SHARES)` on empty vault == 0 | revert `DepositTooSmall` — update test |
| `previewDeposit` in catastrophic state (`totalAssets()==0` with supply>0) == 0 | revert `VaultEmpty` — update test |

Likely 3-5 test assertions to flip. No behavior change for the happy path.

### Storage impact

None.

### Risk

Low. Spec-aligning change. The only consumer category that breaks is "integrators expecting `previewDeposit` to never revert" — but per ERC-4626 they shouldn't expect that anyway.

---

## Fix #17 — `maxRedeem` / `maxWithdraw` reflect claimable balance

### Problem

`maxRedeem` (`HDCLVault.sol:990-993`) and `maxWithdraw` (`HDCLVault.sol:985-987`, in the earlier section) both hardcode `return 0` with the comment "async-only."

Per ERC-7540 (which we explicitly conform to — `supportsInterface(IERC7540Redeem)` returns true):

> `maxRedeem(operator)` MUST equal the share value of all settled but unclaimed requests of the operator.
> `maxWithdraw(operator)` MUST equal the asset value of all settled but unclaimed requests of the operator.

Returning 0 routes 4626-aware integrators away from settled funds (they'd skip the user thinking nothing is redeemable, when in fact `claimableRedeemRequest(reqId, user) > 0`).

### Existing infrastructure that makes this cheap

The DoS fix in `0a3618c` added `_settledByController` — a per-controller index of request IDs with `hdclSettled > 0`. The list is bounded by the user's own activity (cancel-spam can't bloat it). Walking it for max-* is O(user's own settled requests).

### Fix

```solidity
function maxRedeem(address controller) external view returns (uint256 max) {
    uint256[] storage ids = _settledByController[controller];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
        QueueLib.Request storage r = redemptionQueue[ids[i]];
        // Defensive: index can temporarily hold stale entries that
        // claim hasn't swap-popped yet. r.user filter handles cancel/drain.
        if (r.user == controller) max += r.hdclSettled;
    }
}

function maxWithdraw(address controller) external view returns (uint256 max) {
    uint256[] storage ids = _settledByController[controller];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
        QueueLib.Request storage r = redemptionQueue[ids[i]];
        if (r.user == controller) max += r.hollarOwed;
    }
}
```

Both lose their `pure` modifier (need to read storage); they become `view`. ERC-4626's signature is `view`-compatible (the spec doesn't mandate `pure`).

### Affected tests

`test/unit/ProcessPosition.t.sol:test_asyncOnlyViews_alwaysZero` (added in the coverage commit) asserts both return 0 — needs update.

Probably:
- Rename to `test_maxRedeem_maxWithdraw_matchClaimable`
- Setup: alice deposits, requests redeem, pokeQueue settles
- Assert `maxRedeem(alice) == aliceHdclAmount`
- Assert `maxWithdraw(alice) == aliceHollarOwed`
- Assert both return 0 for an unrelated address
- Assert both return 0 before pokeQueue settles
- Assert both drop after a partial `redeem` call

### Spec gotcha — `previewWithdraw` stays at 0

ERC-4626 also has `previewWithdraw(assets) → shares`. For async vaults, ERC-7540 doesn't redefine its behavior. Our current `previewWithdraw` returns 0 unconditionally. **Leave it.** It's the documented "sync withdraw not supported" sentinel. Strict 4626 consumers will see `maxWithdraw > 0` and call `withdraw` directly; they don't need a meaningful preview because the rate is already locked in at settlement.

If we wanted to be more helpful, `previewWithdraw(assets)` could return the share count that would be burned given the controller's settled inventory — but that requires a controller arg (which the 4626 signature lacks). Pass on this; current behavior is defensible.

### Storage impact

None.

### Risk

Low. The bound is the user's own activity (already proven by the DoS fix's invariant tests). One existing unit test to update.

---

## Sequencing & verification

```
[ ] Fix #13: bound _advancePositionHead + call from pokeQueue
    [ ] Add MAX_POSITION_HEAD_SWEEP = 50 constant
    [ ] Bound _advancePositionHead loop
    [ ] Add _advancePositionHead() call in pokeQueue after queue processing
    [ ] 3 new tests in ProcessPosition.t.sol (or new file)
    [ ] forge test → all green
    [ ] Measure vault size — likely +20 bytes; check still under EIP-170

[ ] Fix #4: previewDeposit reverts on math edges
    [ ] Swap returns-0 paths for revert(ZeroAmount/DepositTooSmall/VaultEmpty)
    [ ] Update 3-5 assertions in PreviewDeposit.t.sol
    [ ] forge test → all green

[ ] Fix #17: maxRedeem/maxWithdraw walk _settledByController
    [ ] Replace pure 0-returns with view loops
    [ ] Rewrite test_asyncOnlyViews_alwaysZero → 4-5 new assertions
    [ ] forge test → all green

[ ] Combined size check at runs=100 — should still have ~150B+ buffer under EIP-170
[ ] forge coverage --no-match-coverage "(test|script|mocks)" — should stay ≥ 99% lines
[ ] Re-run lark deploy + e2e against new contract
```

## Out of scope for this batch

- The `_advancePositionHead` issue in `cancelRedeem`'s head-sweep is already bounded (line 591-601) — no change needed there.
- `getEstimatedWaitTime`'s unbounded loops (#19) — separate concern, view-only DoS, deferred.
- `requestId`-aware claim helpers (per-request claim) — would let `previewWithdraw(assets, controller)` give meaningful output. Defer; current return-0 is documented.

## Why not also #16 (oracle roundId) here?

Different file (`WDCLOracle.sol`), different audience (Chainlink consumers, not vault users). Worth doing but cleaner as its own commit so an upgrade can ship without it if oracle integration timing differs.
