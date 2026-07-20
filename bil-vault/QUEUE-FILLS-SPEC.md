# Queue Fills v1 — implementation spec

Buildable spec for **Variant B** of `QUEUE-FILLS-PLAN.md` (strict-FIFO
early settlement with partial fills). The plan holds the rationale; this
holds what to type. All line references are to current `feat/bil`.

## 0. Summary of the mechanism

Exiters opt in by setting an **ask** (discount in bps) on their queued
request. A filler calls `fillQueue(maxHollarIn, maxAskBps, minBilOut)`:
their HOLLAR walks the queue from the head, paying each listed,
affordable entry's controller `pending × rate × (1 − ask)` and moving the
escrowed hDCL to the filler. The last entry is filled partially if the
budget runs short. Filled entries leave the queue (or shrink in place);
settled slices are never touched. No vault accounting changes:
`exchangeRate`, `totalAssets`, `idleHollar`, `totalReservedHollar` are
all invariant across any fill.

## 1. Storage (BILVault.sol)

Append immediately before `uint256[47] private __gap;` (BILVault.sol:1643),
decrement gap to 45:

```solidity
/// @notice requestId → ask discount in bps, stored offset by +1
///         (0 = not listed). Cleared on delist, full drain, and cancel.
mapping(uint256 => uint32) internal _fillAskPlusOne;
/// @notice Global fills switch. Ships false; flipped by admin after
///         keeper/indexer/UI are live.
bool public fillsEnabled;
```

New constant (next to `MAX_QUEUE_ITERATIONS`, BILVault.sol:45):

```solidity
/// @notice Ask ceiling: 20%. Fat-finger guard, not an economic bound.
uint32 internal constant MAX_FILL_ASK_BPS = 2_000;
uint32 internal constant BPS = 10_000;
```

No initializer changes — `fillsEnabled=false` and an empty mapping are
the correct genesis. **No `reinitializer` needed for the upgrade.**

## 2. Vault functions

### 2.1 `setFillAsk`

```solidity
/// @notice List (or re-price) the pending portion of a redemption
///         request for third-party filling at `askBps` below NAV.
/// @dev    Controller or approved ERC-7540 operator. Listing is allowed
///         while fills are disabled (the flag gates only fillQueue), so
///         enabling fills later doesn't require everyone to re-list.
function setFillAsk(uint256 requestId, uint32 askBps) external {
    if (requestId >= queueTail) revert InvalidRequestId();
    if (askBps > MAX_FILL_ASK_BPS) revert AskTooHigh();
    QueueLib.Request storage r = redemptionQueue[requestId];
    address controller = r.user;
    if (controller == address(0)) revert RequestNotActive();
    if (msg.sender != controller && !isOperator[controller][msg.sender])
        revert NotRequestOwner();
    if (r.bilAmount == r.bilSettled) revert NothingPending();
    _fillAskPlusOne[requestId] = askBps + 1;
    emit FillAskSet(requestId, controller, askBps);
}
```

### 2.2 `clearFillAsk`

Same auth; `delete _fillAskPlusOne[requestId]`; emits
`FillAskCleared(requestId)`. Also called internally by:

- `cancelRedeem` (BILVault.sol:596) — add `delete _fillAskPlusOne[requestId]`
  next to the entry shrink/delete. A cancelled request must never remain
  fillable. (Only touch to an existing function.)
- the fill walk, when an entry's pending is fully drained.

### 2.3 `fillQueue`

```solidity
/// @notice Buy queued BIL strictly head-first from listed exiters.
/// @param maxHollarIn  Budget; pulled from msg.sender per filled entry.
/// @param minAskBps    The filler's price filter: fill only entries
///                     asking a discount ≥ this; cheaper-discount
///                     entries are skipped, never stopped at. 0 = fill
///                     every listed entry. See semantics note below.
/// @param minBilOut    Slippage guard on total shares received.
function fillQueue(uint256 maxHollarIn, uint32 minAskBps, uint256 minBilOut)
    external nonReentrant whenNotPaused
    returns (uint256 hollarSpent, uint256 bilReceived)
{
    if (!fillsEnabled) revert FillsDisabled();
    if (maxHollarIn == 0) revert ZeroAmount();
    _syncBeforeRateSensitiveAction();          // BILVault.sol:1569
    uint256 rate = exchangeRate();

    QueueLib.FillResult memory res = QueueLib.fillWalk(
        redemptionQueue,
        _fillAskPlusOne,
        queueHead, queueTail,
        maxHollarIn, minAskBps, rate,
        MAX_QUEUE_ITERATIONS, MAX_QUEUE_SKIPS, WAD
    );

    queueHead = res.newQueueHead;
    totalQueuedBil -= res.bilFilled;

    if (res.bilFilled == 0) revert NothingFilled();
    if (res.bilFilled < minBilOut) revert SlippageExceeded();

    // Interactions — all queue state is already written (CEI).
    for (uint256 i; i < res.count; ++i) {
        hollar.safeTransferFrom(msg.sender, res.pays[i].controller, res.pays[i].amount);
    }
    _transfer(address(this), msg.sender, res.bilFilled);   // escrow → filler

    emit QueueFilled(msg.sender, res.hollarSpent, res.bilFilled, res.count);
    return (res.hollarSpent, res.bilFilled);
}
```

**`minAskBps` semantics.** The filler's price filter: only entries with
`ask ≥ minAskBps` are filled; cheaper-discount (more expensive) entries
are *skipped*, not stopped at — an aggressive ask prices out its own
entry only, never gates the queue behind it (plan §9). `minAskBps = 0`
fills every listed entry.

**Why the payment loop lives in the vault, not QueueLib.** The walk
mutates queue storage inside the DELEGATECALLed library (same pattern as
`processQueue`), but hDCL escrow release needs the vault's internal
ERC-20 `_transfer`, which a library cannot call. So `fillWalk` returns a
memory plan (`pays[]`, bounded by `MAX_QUEUE_ITERATIONS = 50`) and the
vault executes payments after all state writes — which also gives CEI
for free. Shares aggregate to a single `_transfer` since they all go to
one filler.

### 2.4 `setFillsEnabled(bool)` — `ADMIN_ROLE` to enable,
`onlyAdminOrGuardian` (BILVault.sol:1284) to disable (guardian can kill,
only admin can arm — mirrors the pause conventions). Emits
`FillsEnabledSet(bool)`.

### 2.5 View helpers

```solidity
/// requestId → (listed, askBps). Unpacks the +1 offset.
function getFillAsk(uint256 requestId) external view returns (bool, uint32);

/// Simulate fillWalk for UI/keeper quoting. Same walk, no writes.
function previewFillQueue(uint256 maxHollarIn, uint32 minAskBps)
    external view returns (uint256 hollarSpent, uint256 bilOut, uint256 entries);
```

## 3. QueueLib.fillWalk

```solidity
struct FillPay { address controller; uint256 amount; }
struct FillResult {
    uint256 newQueueHead;
    uint256 hollarSpent;
    uint256 bilFilled;
    uint256 count;
    FillPay[] pays;      // length == count
}
```

Walk skeleton mirrors `processQueue` (QueueLib.sol:336) — cursor from
head, `iterations < maxIterations && skips < maxSkips`, head advances
only while co-located with the cursor:

| entry state | action |
|---|---|
| `user == 0` (hole) | skip++, head-advance if co-located |
| `bilSettled == bilAmount` (nothing pending) | skip++, head-advance if co-located |
| unlisted (`askPlusOne == 0`) or `ask < minAskBps` | skip++, **no** head advance (entry is alive — head must not pass it) |
| listed & affordable in full | fill whole pending (below), iterations++ |
| listed, budget short | partial fill (below), stop |

Full fill of `pending = bilAmount − bilSettled` at `ask`:

```
pay          = pending × rate / wad;             // NAV value (settlement rounding, QueueLib.sol:389)
pay          = pay × (BPS − ask) / BPS;          // discount, floor (residue favors filler, <1 wei)
if (pay == 0) break;                             // catastrophic-rate guard, mirrors QueueLib.sol:395
budget      −= pay;
r.bilAmount  = r.bilSettled;                     // exact cancel-shrink (BILVault.sol:611)
delete ask;
if (r.bilSettled == 0) delete queue[cursor];     // hole; head-advance if co-located
else                    /* stays for claim */    // head-advance if co-located (pending == 0 now)
record pays[count++] = (controller, pay); bilFilled += pending;
emit RequestFilled(cursor, controller, pay, pending);
```

Partial fill when `budget < pay` (mirrors partial settlement,
QueueLib.sol:421):

```
shares = budget × wad × BPS / (rate × (BPS − ask));  // floor
if (shares == 0) break;                              // dust guard
pay    = shares × rate / wad × (BPS − ask) / BPS;    // recompute from shares, floor ⇒ pay ≤ budget
r.bilAmount −= shares;                               // pending shrinks in place; ask persists
record pays[count++] = (controller, pay); bilFilled += shares;
emit RequestPartiallyFilled(cursor, controller, pay, shares);
break;                                               // budget exhausted
```

The event pair is emitted from the library like `RedemptionFulfilled` /
`RedemptionPartiallyFulfilled` already are (QueueLib.sol:56).

Rounding rule (same convention as settlement's "truncation residue stays
in idleHollar", QueueLib.sol:426): all floors favor the **payer-side
residue holder** — here the filler — by sub-wei amounts. Document, don't
fight it.

## 4. Events & errors (canonical list)

```solidity
event FillAskSet(uint256 indexed requestId, address indexed controller, uint32 askBps);
event FillAskCleared(uint256 indexed requestId);
event RequestFilled(uint256 indexed requestId, address indexed controller,
                    uint256 hollarPaid, uint256 bilFilled);          // QueueLib
event RequestPartiallyFilled(uint256 indexed requestId, address indexed controller,
                    uint256 hollarPaid, uint256 bilFilled);          // QueueLib
event QueueFilled(address indexed filler, uint256 hollarSpent,
                  uint256 bilReceived, uint256 entriesTouched);      // vault, batch summary
event FillsEnabledSet(bool enabled);

error FillsDisabled(); error AskTooHigh(); error NothingPending();
error NothingFilled(); error SlippageExceeded();
// reused: InvalidRequestId, RequestNotActive, NotRequestOwner, ZeroAmount
```

`RequestFilled.controller` + hDCL `Transfer(vault → filler)` +
`QueueFilled.filler` give indexers the full picture; no filler field is
needed on the per-entry events (it's the tx sender / batch event).

## 5. Invariants (extend the fuzz suite with `fillQueue` + `setFillAsk` actions)

For any single `fillQueue` call, with Σ over its `pays[]`:

1. `exchangeRate`, `totalAssets`, `idleHollar`, `totalReservedHollar`,
   `totalSupply`, `queueTail` — unchanged.
2. `totalQueuedBil_before − totalQueuedBil_after == bilReceived
   == Δ(filler hDCL balance) == −Δ(vault escrow hDCL balance)`.
3. `hollarSpent == Σ pays.amount ≤ maxHollarIn`; HOLLAR moved only
   filler → controllers (vault HOLLAR balance unchanged).
4. `hollarSpent ≥ bilReceived × rate × (BPS − MAX_FILL_ASK_BPS) / BPS / wad`
   (nobody sold below the global ask floor) and per-entry
   `pay ≥ pending_filled × rate × (BPS − ask) / BPS / wad − 1 wei`.
5. Per touched entry: `bilSettled`, `hollarOwed` unchanged; `user` unchanged.
6. `queueHead` monotonically non-decreasing; never passes an entry with
   pending > 0 that is unlisted or listed (head only passes holes and
   pending==0 entries).
7. Ask lifecycle: cleared ⟺ (entry cancelled ∨ pending fully drained ∨
   explicit clear); partial fill preserves the ask.
8. Idempotent-composability: fill → settle → fill on one entry never
   double-pays: settle operates on `pending` which the fill already
   shrank, and vice versa.

## 6. Interactions audit checklist

- `pokeQueue` reinvest gate (BILVault.sol:912, "no progress this call"):
  fills don't touch `idleHollar` → no interaction. Assert in a test that
  a fill between two `pokeQueue`s doesn't suppress reinvestment.
- `getEstimatedWaitTime` (BILVault.sol:1164): sums queue-ahead HOLLAR
  need — shrinks automatically as fills drain entries. No change needed;
  add a test asserting estimates improve after a fill.
- H-01 surface: fill pricing reads `exchangeRate()` *after*
  `_syncBeforeRateSensitiveAction()`, same discipline as `pokeQueue`.
  An inflated rate makes fills more expensive for the filler (they
  decline); the vault carries zero exposure either way. Self-fill at any
  rate is value-neutral to the vault (test: self-fill changes nothing
  but event emission and ask clearing).
- `maxRedeem`/`maxWithdraw`/claims: read settled state only — untouched.
- ERC-7540 conformance: requests still non-transferable; early exit via
  fill is economically `cancel + OTC`, expressed atomically. No spec
  extension required (plan §9 table).

## 7. Off-chain deltas

**Keeper** (`bil-vault/keeper/`): new `filler` module, config-gated off.
Loop: on `FillAskSet` or every N blocks → `previewFillQueue(budget,
minAskBps)` → if `bilOut > 0` and quote clears `minProfitBps` → send
`fillQueue`. Wallet = treasury-funded ops account. Config:
`{ enabled, budgetHollar, minAskBps, minProfitBps, maxTxPerHour }`.

**UI** (`hydration-ui` bil module):
- `WithdrawalsCard` row action "Sell early": modal with ask slider →
  proceeds preview `pending × rate × (1 − ask)` vs "wait ≈ N days for
  full NAV" (reuse the queue-vs-instant comparison layout); badge
  `Listed @ x%` from `getFillAsk`; "Delist" secondary action.
- Row history: `RequestFilled` / `RequestPartiallyFilled` from the
  indexer render as "Sold early — received X HOLLAR" rows (same shape as
  redeemed rows in `useRedemptionHistory`, keyed by requestId + log index
  since one request can fill many times).
- No buyer-side UI in v1 (fillers are bots/treasury).

**Indexer**: ingest the four new events; extend the redemption-history
query with fill rows.

## 8. Delivery checklist

1. Contracts: storage + `setFillAsk`/`clearFillAsk`/`fillQueue`/admin +
   `QueueLib.fillWalk` + events. (Small; the tests are the bulk.)
2. Tests: unit matrix below, invariant suite extension (§5), gas
   snapshot of `fillQueue` at 1 / 10 / 50 entries.
3. Audit addendum: scope = `fillWalk`, `cancelRedeem` touch, escrow
   `_transfer`, §5 invariants. Same reviewers as H-01/H-02.
4. Deploy: new QueueLib, relink, new impl via `script/Upgrade.s.sol`
   pattern; verify storage layout diff (`forge inspect … storage-layout`)
   shows only the two new slots + gap 47→45.
5. Rehearse upgrade ref on a chopsticks fork of 0.lark; then 0.lark ref;
   e2e with UI preview (list a real request, fill from second account,
   partial fill, claim settled slice afterwards).
6. Mainnet upgrade ref with `fillsEnabled = false`; enable by admin
   action once keeper + indexer are live.

### Unit test matrix

| # | case |
|---|---|
| 1 | list / re-price / delist; ask cap; auth (controller, operator, stranger) |
| 2 | list with nothing pending reverts; list on cancelled/nonexistent reverts |
| 3 | fill single fully-pending entry — entry deleted, head advanced, escrow moved, payment exact |
| 4 | fill entry with settled slice — slice untouched & claimable after, entry retained, head passes |
| 5 | partial fill — pending shrinks, ask persists, second fill completes it |
| 6 | walk skips: hole, unlisted, ask < minAskBps, fully-settled; head never passes live entries |
| 7 | budget stops mid-strip; `minBilOut` violation reverts; `NothingFilled` reverts |
| 8 | fill vs cancel race (cancel first → skip; fill first → cancel gets remaining pending only) |
| 9 | fill vs settle race (settle shrinks pending; fill pays only the rest) |
| 10 | cancel clears ask; full drain clears ask |
| 11 | fills disabled / paused / maturity backlog → revert |
| 12 | self-fill is value-neutral |
| 13 | rounding: pay ≤ budget always; per-share price within 1 wei of quoted |
| 14 | iteration cap: 51 listed entries → 50 filled, head correct, second call finishes |
| 15 | reinvest gate + wait-estimate assertions (§6) |

## 9. Open questions (decide before implementation)

1. **Operator listing** — plan §3 says operators may list; payment always
   to controller. Confirm with team (matches `cancelRedeem` refund rule).
2. **`minAskBps` vs per-entry `maxPricePerShare`** — current spec filters
   by ask; a price-per-share bound is equivalent given rate is read
   in-tx. Ask filter is simpler; revisit only if quote/tx rate drift
   ever matters (rate moves ~0.05%/day — it doesn't).
3. **Event for skipped-but-listed entries** — omitted (walk is
   simulatable via `previewFillQueue`); confirm indexer doesn't need it.
