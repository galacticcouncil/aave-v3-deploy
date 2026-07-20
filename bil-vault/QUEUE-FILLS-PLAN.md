# Queue Fills — implementation plan

Third-party early-exit for queued redemptions: a filler pays a queued
redeemer HOLLAR now and takes over their queue entry, inheriting its FIFO
priority. The exiter gets paid immediately at their own asking price; the
filler earns the discount for waiting out the remaining queue time (while
the escrowed shares keep accruing — settlement rate-locks at fulfillment,
so a queue spot is never yield-dead).

> **Two variants are specced below.** §1–§5 describe Variant A (spot
> transfer — filler inherits the queue position). §9 describes Variant B
> (strict-FIFO early settlement — external HOLLAR pays sellers head-first
> and filled entries leave the queue). **§9's recommendation: ship B as
> v1**; A layers on later if targeted fills prove necessary.

**Status: post-mainnet-launch feature. Explicitly NOT in the launch scope.**
The launch ships queue + stableswap only; this is an upgrade once the vault
has real usage. Rationale: it touches the escrow/claim area where audit
finding H-01 lived, and there is no filler ecosystem at launch TVL anyway.

Why it beats the stablepool for this job: the pool's convex curve makes
large instant exits expensive (measured on lark: 200K one-way flow → 7.8%
marginal discount at amp 50), while a fill is flat-priced at any size. And
a pool buyer must `requestRedeem` at the back of the queue, whereas a
filler inherits the entry's position near the head — shorter capital
lockup → tighter viable discounts → cheaper exits for everyone.

## 1. Design summary — whole-entry buyout, registry-only change

The single most important property: **a fill never touches vault
accounting.** No hDCL moves (it stays escrowed in the vault), `idleHollar`
/ `totalReservedHollar` / `totalQueuedBil` / `exchangeRate()` are all
unchanged. The vault only (a) reassigns `Request.user` and (b) forwards
the filler's HOLLAR payment to the old controller. H-01/H-02 defenses,
the maturity heap, and settlement logic are untouched.

Mechanics:

- The controller lists their request by setting an **ask discount** (bps).
  Limit-order semantics — no oracle-driven pricing, no auction. v2 can add
  a wait-time-indexed curve; v1 keeps price discovery with the seller.
- `fulfillRequest(requestId, maxHollarIn)` — anyone. Price, computed at
  fill time from current entry state:

  ```
  pending  = bilAmount − bilSettled
  price    = hollarOwed                                   // settled: face value, riskless
           + pending × exchangeRate() × (1 − askBps/1e4)  // pending: discounted
  ```

  The settled slice is bought at face (it is already fixed HOLLAR — zero
  risk), which avoids splitting the entry. One entry, one owner, always.
  `exchangeRate()` is internal NAV, not spot — not moveable by pool trades.
- Effects: pay `price` HOLLAR filler → old controller (direct
  `safeTransferFrom`, never enters vault balances); `request.user = filler`;
  clear the ask; if `bilSettled > 0`, push `requestId` into
  `settledByController[filler]` (the old controller's index entry goes
  stale and is lazily evicted by the existing swap-pop in
  `QueueLib.claimByShares` — that path already tolerates stale ids).

## 2. Contract changes

### BILVault.sol

Storage (append before `__gap`, decrement gap 47 → 45):

```solidity
/// requestId → ask discount in bps, offset by +1 (0 = not listed).
mapping(uint256 => uint32) internal fillAskPlusOne;
/// Global kill switch, admin-set. Ships disabled.
bool public fillsEnabled;
```

New functions:

- `setFillAsk(uint256 requestId, uint32 askBps)` — controller or
  `isOperator[controller][msg.sender]` (same auth shape as `cancelRedeem`,
  BILVault.sol:596). `askBps ≤ MAX_FILL_ASK_BPS` (2_000 = 20%, constant —
  fat-finger guard). `askBps == type(uint32).max` sentinel to delist, or a
  separate `clearFillAsk`. Requires pending portion > 0.
- `fulfillRequest(uint256 requestId, uint256 maxHollarIn)` —
  `nonReentrant whenNotPaused`. Checks: `fillsEnabled`, entry listed,
  `request.user != address(0)`, computed `price ≤ maxHollarIn` (races with
  cancel/settlement change the price — see §4). Effects before
  interaction; payment last. Emits `RequestFilled`.
- Admin: `setFillsEnabled(bool)` — `onlyAdminOrGuardian` off,
  `ADMIN_ROLE` on (mirrors the pause conventions at BILVault.sol:1295).

Events / errors:

```solidity
event FillAskSet(uint256 indexed requestId, address indexed controller, uint32 askBps);
event RequestFilled(uint256 indexed requestId, address indexed oldController,
                    address indexed filler, uint256 hollarPaid,
                    uint256 bilPending, uint256 bilSettled);
error FillsDisabled(); error NotListed(); error AskTooHigh(); error PriceAboveMax();
```

### QueueLib.sol

`transferRequest(queue, settledByController, requestId, newController)` —
the reassignment + settled-index bookkeeping lives next to the claim code
that consumes it. Vault stays under EIP-170 (same DELEGATECALL split
reason the library exists, see garden spec §"QueueLib").

### What deliberately does NOT change

- `requestRedeem` / `cancelRedeem` / `redeem` / `withdraw` / settlement /
  `pokeQueue` / `totalAssets()` — byte-for-byte untouched.
- The auto-claim flag is per-controller (BILVault.sol:196), not per-entry —
  nothing to migrate on fill; the filler manages their own flag.
- ERC-7540 note: the spec leaves request transferability as an extension.
  `RequestFilled` is our extension event; document that `RedeemRequest`'s
  original controller is superseded by the latest `RequestFilled`.

## 3. Authorization & payment rules

| Action | Who | Payment goes to |
|---|---|---|
| `setFillAsk` | controller or ERC-7540 operator | — |
| `fulfillRequest` | anyone (incl. self — harmless no-op economically) | always the **controller** (like `cancelRedeem`'s refund rule — operators can list but never redirect the proceeds) |
| after fill: `cancelRedeem`, ask re-list, claim | new controller (filler) | filler |

## 4. Edge cases & races

1. **Fill vs cancel** — cancel shrinks/deletes the entry first → fill sees
   `pending == 0` / unlisted and reverts. Reverse order: filled entry's
   old controller can no longer cancel (auth is against `request.user`). ✓
2. **Fill vs settlement** — `pokeQueue` settles a slice between listing
   and fill: pending→settled moves that slice from discounted to face
   pricing, total price rises. `maxHollarIn` is the filler's slippage
   guard; recomputing at execution keeps it exact.
3. **Partial-settle after fill** — future settlements push the id into
   `settledByController[filler]` (existing code paths, since `user` is now
   the filler). Verify no duplicate-push assumptions — the claim walk
   already tolerates duplicates via the stale-eviction swap-pop
   (QueueLib.sol:473).
4. **Re-listing** — filler can set their own ask and be bought out again.
   Chained fills are fine; each clears the previous ask.
5. **Dust** — whole-entry buyout means no entry splitting, so
   `minRedeemAmount` invariants can't be violated by fills.
6. **Pause semantics** — `whenNotPaused` on fills (consistent with
   claims); `fillsEnabled` kill switch independent of pause.
7. **Reentrancy** — HOLLAR (GHO) has no transfer hooks; belt-and-braces:
   `nonReentrant`, all state written before `safeTransferFrom`.

## 5. Invariants (must hold before == after any fill)

- `exchangeRate()`, `totalAssets()`, `idleHollar`, `totalReservedHollar`,
  `totalQueuedBil`, vault hDCL escrow balance, `queueHead`/`queueTail`.
- `bilAmount/bilSettled/hollarOwed` of the filled entry — only `user`
  changes.
- Sum over `settledByController` of live settled shares per controller
  matches entries' `bilSettled` (modulo lazily-evicted stale ids).

## 6. Off-chain work

- **Keeper** (`bil-vault/keeper/`): optional `filler` module — treasury
  as first market-maker: watch `FillAskSet`, fill anything with
  `askBps ≥ minProfitBps` given estimated wait (reuses
  `getEstimatedWaitTime`). Config-gated, off by default.
- **UI** (`hydration-ui` bil module): per-row "Sell your spot" on
  `WithdrawalsCard` (set/clear ask, show live fill price next to the
  existing queue-vs-instant comparison); row state "Filled — paid early"
  from `RequestFilled` (indexer). Buyer-side UI deferred — v1 buyers are
  bots/treasury. Third exit option in the withdraw modal comparison:
  queue (full NAV, wait) / instant pool (spot discount, now) / listed fill
  (your ask, when taken).
- **Indexer**: `FillAskSet` + `RequestFilled` into the redemption-history
  feed (`useRedemptionHistory` keys rows by requestId — needs the
  controller-change join).

## 7. Testing

- **Unit (foundry, `bil-vault/test/`)**: happy path unsettled / partially
  settled / fully settled; price math incl. ask bounds and the +1 offset;
  auth matrix (controller / operator / stranger / role holders); races §4
  as explicit sequences; kill switch; pause.
- **Invariant/fuzz**: extend the existing invariant suite with
  `fulfillRequest` in the action set; assert §5 invariants; fuzz
  interleavings of settle/cancel/fill/claim on the same entry.
- **Fork rehearsal**: chopsticks fork of 0.lark → upgrade → list a real
  queued request → fill from a second account → claim as filler after
  maturity settlement. Then the same on 0.lark itself via ref.
- **e2e**: UI flow on the lark preview against the upgraded vault.

## 8. Rollout

1. Implement + tests (contract work is small; the test surface is the work).
2. **Audit addendum** — mandatory, not optional: same reviewers who did
   H-01/H-02, scoped to QueueLib claim-index handling + the new surface.
3. Deploy new `QueueLib` + vault impl; governance `upgradeTo`
   (UPGRADER_ROLE is governance, UUPS, instant — no timelock).
4. Rehearse the upgrade ref on a chopsticks fork of 0.lark, then enact on
   0.lark, e2e there.
5. Mainnet upgrade ref, `fillsEnabled = false` initially; enable by
   separate admin action once the keeper/indexer/UI pieces are live.

## 9. Variant B — strict-FIFO early settlement (recommended v1)

Variant A (§1–§5, "spot transfer") leaves *settlement* strictly FIFO but
makes *liquidity timing* a market: fillers cherry-pick entries, so a
later requester can be paid before an earlier one. If the product norm is
"whoever has waited longest has first claim on any early liquidity",
there is a strictly-FIFO alternative — and it turns out to be simpler,
not harder.

### Mechanics

The filler doesn't buy a queue *spot* — they buy the queued *BIL*, in
queue order. External HOLLAR walks the queue from the head exactly like
settlement does, paying opted-in exiters at their asks; filled entries
leave the queue and the filler receives the escrowed hDCL:

```solidity
/// Walk from queueHead. For each active entry that is listed with
/// ask ≤ maxAskBps: pay controller pendingBil × rate × (1 − ask),
/// receive the pending escrowed shares, remove entry from queue.
/// Whole entries only — stop when the next fillable entry exceeds the
/// remaining budget. Unlisted / over-ask entries are skipped (counted
/// against maxSkips like settlement holes).
function fillQueue(uint256 maxHollarIn, uint32 maxAskBps)
    external nonReentrant whenNotPaused
    returns (uint256 hollarSpent, uint256 bilReceived);
```

Per entry, the effects are `cancelRedeem`'s (BILVault.sol:596) with two
substitutions: the pending shares go to the **filler** instead of back to
the controller, and the controller receives the filler's HOLLAR. Settled
slices (`bilSettled`/`hollarOwed`) are untouched — they stay claimable by
the original controller, so **no controller reassignment exists at all**:
no `settledByController` index migration, no face-value purchase of
settled slices, none of §4.3's duplicate-push concerns. The walk itself
mirrors `QueueLib.processQueue` (QueueLib.sol:336) — same cursor/hole-skip
/iteration-cap scaffolding, same head-compaction rules.

Accounting: `totalQueuedBil` decreases and entries delete/shrink — the
existing audited cancel semantics. `exchangeRate()`/`totalAssets()`
unchanged (shares transfer, nothing burns; the payment never enters vault
balances). Call `_syncBeforeRateSensitiveAction` before pricing, same as
every other rate consumer.

### Why skip, not stop, at non-sellers

Strictly stopping at the first unlisted entry hands a veto to whoever is
at the head: a 1-BIL entry that refuses to list would block early
liquidity for a 500K entry behind it forever. Skipping preserves the
real invariant — *among exiters willing to sell at the market's price,
earlier requests are always paid first* — while making non-participation
self-exclusion rather than griefing. Same argument for skipping asks
above the filler's `maxAskBps`: an aggressive ask only prices its own
entry out, never gates the queue behind it.

### Emergent properties

- **Fills shorten the queue for everyone.** Filled entries leave the
  queue, so everyone behind moves up — `getEstimatedWaitTime` improves,
  which shrinks the discount future sellers need. Fills are a public
  good here; in Variant A they're neutral.
- **Whale demand pays small sellers first.** A filler reaching for a
  large attractive ask deep in the queue must clear every cheaper listed
  ask ahead of it — small early exiters get paid as a side effect.
- **The filler is a BIL buyer, not a queue arbitrageur.** They end up
  holding BIL at NAV-minus-ask with no size impact — strictly better
  than buying through the pool's convex curve. Natural demand is anyone
  who wants BIL exposure at scale (incl. the treasury bot), not just
  exit-flow speculators. They inherit no priority; if they later want
  out, they queue at the back or use the pool like any holder.

### Trade-offs vs Variant A

| | A — spot transfer | B — strict-FIFO early settlement |
|---|---|---|
| Payment order | market (cherry-pick) | FIFO among sellers |
| Others' wait | unchanged | shortened |
| Whale in back | served directly | only after cheaper asks ahead clear |
| Filler gets | queue spot near head | BIL (no priority) |
| Viable discounts | tightest (short lockup) | ask must beat "just buy & hold BIL" |
| Contract diff | controller reassignment + settled-slice purchase + index migration | cancel-with-different-destination + head walk |
| ERC-7540 | transferable-request extension | none needed (entries just exit early) |
| §4 races | 3 interactions to reason about | fill vs settle/cancel only; no settled-slice cases |

The §2–§5 sections above carry over with these deltas: storage is the
same `fillAskPlusOne` mapping + `fillsEnabled`; `setFillAsk` unchanged;
`fulfillRequest(requestId, ...)` is replaced by `fillQueue(maxHollarIn,
maxAskBps)`; the §5 invariants swap "totalQueuedBil unchanged" for
"totalQueuedBil decreases by exactly the pending shares transferred, and
vault escrow balance decreases by the same".

### Recommendation

Ship **B as v1**. It answers the fairness question by construction, is a
smaller and more familiar diff (cancel semantics + settlement-walk
scaffolding, both existing audited surface), and serves the realistic
buyer (someone who wants BIL at size without pool impact). Revisit A as
a v2 *only* if practice shows demand for targeted mid-queue fills that
strip-clearing doesn't satisfy — the storage and listing surface are
shared, so A layers on later without migration.

## 10. Out of scope (v2 candidates)

- Auction / wait-time-curve pricing (v1 is seller-set limit orders).
- Public buyer-side order-book UI.
- Partial fills (buy a slice of an entry) — rejected for v1: forces entry
  splitting, which breaks the one-entry-one-owner simplicity and
  re-introduces dust/minRedeem questions.
- Composability wrapper (tokenized queue positions) — explicitly against
  the product principle that users never touch NFTs/positions.
