// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDecentralPool} from "../interfaces/IDecentralPool.sol";
import {IAggregatorV3Interface} from "../interfaces/IAggregatorV3Interface.sol";

/// @title QueueLib
/// @notice Shared BILVault mechanics deployed as a linked library to keep the
///         vault below EIP-170. Storage-bearing helpers receive each storage
///         reference explicitly; accounting helpers return aggregate deltas
///         for the vault to apply at the call boundary.
library QueueLib {
    using SafeERC20 for IERC20;

    uint256 private constant MATURITY_SHIFT = 128;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD_ = 1e18;
    /// @dev Same work/skip budgets as the vault's pokeQueue constants —
    ///      owned here for the fill path so the vault doesn't spend
    ///      bytecode marshaling them (EIP-170).
    uint256 private constant MAX_FILL_ITERATIONS = 50;
    uint256 private constant MAX_FILL_SKIPS = 500;
    /// @notice Sentinel askBps for setAsk meaning "delist".
    uint32 public constant CLEAR_ASK = type(uint32).max;

    enum NFTState {
        Active,
        YieldWithdrawalRequested,
        YieldClaimed,
        PrincipalWithdrawalRequested,
        Redeemed
    }

    struct NFTPosition {
        uint256 tokenId;
        uint256 principal;
        uint256 apyWad;
        uint256 depositTime;
        uint256 maturityTime;
        uint256 yieldStartTime;
        NFTState state;
        bool yieldCapped;
        uint256 pendingYield;
    }

    /// @notice A queued redemption request.
    struct Request {
        address user;          // controller (= owner under standard flow)
        uint256 bilAmount;    // total hDCL queued (decreases on cancel/claim)
        uint256 bilSettled;   // rate-locked, ready to claim
        uint256 hollarOwed;    // HOLLAR reserved for the settled portion
    }

    /// @dev One payment leg of a fill walk: HOLLAR the filler owes a
    ///      controller whose pending shares were bought. Internal to
    ///      `executeFill` — collected during the walk, paid after all
    ///      state writes (CEI inside the library call).
    struct FillPay {
        address controller;
        uint256 amount;
    }

    error InsufficientClaimable();
    error NothingFilled();
    error AskTooHigh();
    error NothingPending();
    error NotRequestOwner();
    error RequestNotActive();
    error InvalidRequestId();
    error PoolHasOpenPositions();
    error ZeroAddress();
    error PoolAlreadyRegistered();
    error PoolWrongStablecoin();
    error PoolNoNFTContract();
    error PoolTokenMismatch();
    error OracleNotSet();
    error OracleInvalidAnswer();
    error OracleRoundIncomplete();
    error OracleStaleRound();
    error OracleDecimalsOutOfRange();

    event RedemptionFulfilled(
        uint256 indexed requestId,
        address indexed user,
        uint256 hollarAmount,
        uint256 bilBurned
    );
    event RedemptionPartiallyFulfilled(
        uint256 indexed requestId,
        address indexed user,
        uint256 hollarAmount,
        uint256 bilBurned
    );
    event PositionYieldCapped(
        uint256 indexed positionIndex,
        uint256 maturityTime,
        uint256 pendingYield
    );
    /// @notice A controller listed (or re-priced) their request's pending
    ///         portion for third-party filling.
    event FillAskSet(uint256 indexed requestId, address indexed controller, uint32 askBps);
    /// @notice A listing was removed — explicitly, on cancel, or on full drain.
    event FillAskCleared(uint256 indexed requestId);
    /// @notice A request's unsettled portion was cancelled and refunded.
    event RedemptionCancelled(uint256 indexed requestId, uint256 bilReturned);
    /// @notice A fill bought a request's entire pending portion.
    event RequestFilled(
        uint256 indexed requestId,
        address indexed controller,
        uint256 hollarPaid,
        uint256 bilFilled
    );
    /// @notice A fill bought part of a request's pending portion (the
    ///         filler's budget ran out); the remainder stays queued and
    ///         listed at the same ask.
    event RequestPartiallyFilled(
        uint256 indexed requestId,
        address indexed controller,
        uint256 hollarPaid,
        uint256 bilFilled
    );
    /// @notice Batch summary of one fillQueue call. Per-entry detail is in
    ///         RequestFilled / RequestPartiallyFilled.
    event QueueFilled(
        address indexed filler,
        uint256 hollarSpent,
        uint256 bilReceived,
        uint256 entriesTouched
    );

    /// @notice Add a packed `(maturity, positionIndex)` entry to the min-heap.
    /// @dev Kept in the linked library so heap maintenance does not consume
    ///      the vault's EIP-170 bytecode budget.
    function pushMaturity(
        uint256[] storage heap,
        uint256 maturityTime,
        uint256 positionIndex
    ) public {
        require(maturityTime <= type(uint128).max, "maturity overflow");
        require(positionIndex <= type(uint128).max, "position overflow");
        uint256 entry = (maturityTime << MATURITY_SHIFT) | positionIndex;
        heap.push(entry);
        uint256 cursor = heap.length - 1;
        while (cursor > 0) {
            uint256 parent = (cursor - 1) / 2;
            if (heap[parent] <= entry) break;
            heap[cursor] = heap[parent];
            cursor = parent;
        }
        heap[cursor] = entry;
    }

    /// @notice Cap up to `maxPositions` due heap roots and return aggregate
    ///         accounting deltas to the vault.
    function processMaturities(
        NFTPosition[] storage positions,
        uint256[] storage heap,
        uint256 maxPositions,
        uint256 timestamp,
        uint256 rateSum,
        uint256 offsetSum,
        uint256 denominator
    )
        public
        returns (
            uint256 processed,
            uint256 newRateSum,
            uint256 newOffsetSum,
            uint256 pendingYieldAdded
        )
    {
        newRateSum = rateSum;
        newOffsetSum = offsetSum;
        while (processed < maxPositions && heap.length > 0) {
            uint256 entry = heap[0];
            uint256 maturityTime = entry >> MATURITY_SHIFT;
            if (maturityTime > timestamp) break;
            uint256 positionIndex = uint128(entry);

            _popMaturity(heap);
            NFTPosition storage pos = positions[positionIndex];
            uint256 rate = pos.apyWad * pos.principal;
            uint256 capped = (rate * (maturityTime - pos.yieldStartTime)) /
                denominator;
            pos.pendingYield = capped;
            pos.yieldCapped = true;
            newRateSum -= rate;
            newOffsetSum -= rate * pos.yieldStartTime;
            pendingYieldAdded += capped;
            emit PositionYieldCapped(positionIndex, maturityTime, capped);
            unchecked { ++processed; }
        }
    }

    function _popMaturity(uint256[] storage heap) private {
        uint256 lastIndex = heap.length - 1;
        uint256 last = heap[lastIndex];
        heap.pop();
        if (lastIndex == 0) return;

        uint256 cursor;
        uint256 len = heap.length;
        while (true) {
            uint256 left = cursor * 2 + 1;
            if (left >= len) break;
            uint256 right = left + 1;
            uint256 smallest = right < len && heap[right] < heap[left]
                ? right
                : left;
            if (heap[smallest] >= last) break;
            heap[cursor] = heap[smallest];
            cursor = smallest;
        }
        heap[cursor] = last;
    }

    function estimatedWaitTime(
        mapping(uint256 => Request) storage queue,
        NFTPosition[] storage positions,
        mapping(uint256 => IDecentralPool) storage positionPool,
        uint256 requestId,
        uint256 queueHead,
        uint256 positionHead,
        uint256 rate,
        uint256 wad,
        uint256 idleHollar,
        uint256 denominator,
        uint256 timestamp
    ) public view returns (uint256) {
        if (queue[requestId].user == address(0)) return 0;

        uint256 hollarNeeded;
        for (uint256 i = queueHead; i <= requestId; i++) {
            Request storage r = queue[i];
            if (r.user == address(0)) continue;
            hollarNeeded += ((r.bilAmount - r.bilSettled) * rate) / wad;
        }
        if (idleHollar >= hollarNeeded) return 0;
        hollarNeeded -= idleHollar;

        uint256 accumulated;
        for (uint256 i = positionHead; i < positions.length; i++) {
            NFTPosition storage pos = positions[i];
            if (pos.state == NFTState.Redeemed) continue;
            uint256 expectedYield = (pos.principal *
                pos.apyWad *
                (pos.maturityTime - pos.yieldStartTime)) / denominator;
            accumulated += pos.principal + expectedYield;
            if (accumulated >= hollarNeeded) {
                uint256 readyAt = pos.maturityTime +
                    positionPool[i].principalWithdrawalDelaySeconds();
                return readyAt > timestamp ? readyAt - timestamp : 0;
            }
        }
        return type(uint256).max;
    }

    function sumSettled(
        mapping(uint256 => Request) storage queue,
        uint256[] storage ids,
        address controller,
        bool assets
    ) public view returns (uint256 total) {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            Request storage r = queue[ids[i]];
            if (r.user == controller) {
                total += assets ? r.hollarOwed : r.bilSettled;
            }
        }
    }

    function advanceQueueHead(
        mapping(uint256 => Request) storage queue,
        uint256 head,
        uint256 tail,
        uint256 maxIterations
    ) public view returns (uint256) {
        uint256 swept;
        while (
            head < tail &&
            swept < maxIterations &&
            queue[head].user == address(0)
        ) {
            unchecked { ++head; ++swept; }
        }
        return head;
    }

    function advancePositionHead(
        NFTPosition[] storage positions,
        uint256 head,
        uint256 maxIterations
    ) public view returns (uint256) {
        uint256 len = positions.length;
        uint256 swept;
        while (
            head < len &&
            swept < maxIterations &&
            positions[head].state == NFTState.Redeemed
        ) {
            unchecked { ++head; ++swept; }
        }
        return head;
    }

    function removePool(
        NFTPosition[] storage positions,
        mapping(uint256 => IDecentralPool) storage positionPool,
        IDecentralPool[] storage pools,
        uint256 positionHead,
        IDecentralPool pool
    ) public {
        uint256 len = positions.length;
        for (uint256 i = positionHead; i < len; i++) {
            if (
                positions[i].state != NFTState.Redeemed &&
                positionPool[i] == pool
            ) revert PoolHasOpenPositions();
        }

        len = pools.length;
        for (uint256 i; i < len; i++) {
            if (pools[i] == pool) {
                pools[i] = pools[len - 1];
                pools.pop();
                return;
            }
        }
    }

    function registerPool(
        mapping(IDecentralPool => bool) storage isPoolRegistered,
        mapping(address => bool) storage isRegisteredPoolToken,
        IDecentralPool[] storage pools,
        IDecentralPool newPool,
        address expectedStablecoin,
        address expectedPoolToken
    ) public returns (address poolTokenAddr) {
        if (address(newPool) == address(0)) revert ZeroAddress();
        if (isPoolRegistered[newPool]) revert PoolAlreadyRegistered();
        if (address(newPool.stablecoin()) != expectedStablecoin) {
            revert PoolWrongStablecoin();
        }
        poolTokenAddr = address(newPool.poolToken());
        if (poolTokenAddr == address(0)) revert PoolNoNFTContract();
        if (
            expectedPoolToken != address(0) &&
            poolTokenAddr != expectedPoolToken
        ) revert PoolTokenMismatch();

        isPoolRegistered[newPool] = true;
        isRegisteredPoolToken[poolTokenAddr] = true;
        pools.push(newPool);
    }

    function validateOracle(IAggregatorV3Interface candidate) public view {
        (, int256 answer, , uint256 updatedAt, ) = candidate.latestRoundData();
        if (answer <= 0) revert OracleInvalidAnswer();
        if (updatedAt == 0) revert OracleRoundIncomplete();
        uint8 decimals = candidate.decimals();
        if (decimals < 6 || decimals > 18) revert OracleDecimalsOutOfRange();
    }

    function oraclePrice(
        IAggregatorV3Interface oracle
    ) public view returns (uint256) {
        if (address(oracle) == address(0)) revert OracleNotSet();
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = oracle.latestRoundData();
        if (answer <= 0) revert OracleInvalidAnswer();
        if (roundId == 0 || updatedAt == 0) revert OracleRoundIncomplete();
        if (answeredInRound < roundId) revert OracleStaleRound();
        return (uint256(answer) * 1e18) / (10 ** oracle.decimals());
    }

    /// @notice Settle pending requests in FIFO order using `available` HOLLAR
    ///         at the supplied `rate`. Locks HOLLAR into request.hollarOwed
    ///         and marks bilSettled — but does NOT decrement vault-level
    ///         idleHollar or increment totalReservedHollar; the caller must
    ///         apply `hollarUsed` to those globals.
    ///
    ///         Maintains a per-controller index of request IDs with non-zero
    ///         bilSettled. Pushes a request's cursor onto its controller's
    ///         list the first time bilSettled becomes non-zero — making
    ///         later claim walks bounded by the controller's own activity
    ///         instead of the all-time queueTail (cancel-spam DoS fix).
    function processQueue(
        mapping(uint256 => Request) storage queue,
        mapping(address => uint256[]) storage settledByController,
        uint256 queueHead_,
        uint256 queueTail_,
        uint256 available,
        uint256 rate,
        uint256 maxIterations,
        uint256 maxSkips,
        uint256 wad
    )
        public
        returns (uint256 newQueueHead, uint256 hollarUsed, uint256 bilLocked)
    {
        newQueueHead = queueHead_;
        uint256 iterations;
        uint256 skips;
        uint256 cursor = newQueueHead;

        while (
            cursor < queueTail_ &&
            iterations < maxIterations &&
            skips < maxSkips
        ) {
            Request storage request = queue[cursor];

            if (request.user == address(0)) {
                // Cancelled hole — sweep past. Advance queueHead while it's
                // still co-located with the cursor.
                if (cursor == newQueueHead) {
                    unchecked { newQueueHead++; }
                }
                unchecked { cursor++; skips++; }
                continue;
            }

            if (request.bilSettled == request.bilAmount) {
                // Already fully settled — no more processing needed. Advance
                // queueHead past it too if co-located; the entry stays in
                // the mapping for claim walkers to find.
                if (cursor == newQueueHead) {
                    unchecked { newQueueHead++; }
                }
                unchecked { cursor++; skips++; }
                continue;
            }

            // Hit a pending entry. Stop if there's nothing left to settle.
            if (available == 0) break;

            iterations++;

            uint256 pending = request.bilAmount - request.bilSettled;
            uint256 hollarValue = (pending * rate) / wad;

            // Catastrophic-rate guard: if rate has degraded so far that the
            // outstanding BIL is worth zero HOLLAR, settling it would lock
            // value with no payout. Stop the loop — admin intervention is
            // needed before this entry can be safely processed.
            if (hollarValue == 0) break;

            // Capture pre-update state so we can detect the first-time-settle
            // transition without an extra storage read after the writes.
            bool firstSettle = (request.bilSettled == 0);
            address user = request.user;

            if (available >= hollarValue) {
                // Fully settle — leave the entry in place for claim, but
                // advance queueHead/cursor past it.
                request.bilSettled = request.bilAmount;
                request.hollarOwed += hollarValue;

                if (firstSettle) settledByController[user].push(cursor);

                hollarUsed += hollarValue;
                bilLocked += pending;
                available -= hollarValue;

                emit RedemptionFulfilled(cursor, user, hollarValue, pending);

                if (cursor == newQueueHead) {
                    unchecked { newQueueHead++; }
                }
                unchecked { cursor++; }
            } else {
                // Partially settle
                uint256 bilToSettle = (available * wad) / rate;
                if (bilToSettle == 0) break; // Dust amount, stop

                // Lock only the HOLLAR equivalent of the rate-locked BIL at
                // the current rate, not the full `available`. The truncation
                // residue (sub-wei vs `rate`) stays in idleHollar — it
                // benefits the vault, not the redeemer.
                uint256 hollarToReserve = (bilToSettle * rate) / wad;

                request.bilSettled += bilToSettle;
                request.hollarOwed += hollarToReserve;

                if (firstSettle) settledByController[user].push(cursor);

                hollarUsed += hollarToReserve;
                bilLocked += bilToSettle;
                available = 0;

                emit RedemptionPartiallyFulfilled(
                    cursor,
                    user,
                    hollarToReserve,
                    bilToSettle
                );
                // Entry stays at cursor (more pending to settle next call).
                // Don't increment cursor — break out via available == 0 check.
            }
        }
    }

    /// @notice List, re-price, or delist a request's pending portion for
    ///         third-party filling. `askBps == CLEAR_ASK` delists
    ///         (idempotent). Auth: controller or approved ERC-7540 operator
    ///         (delegatecall preserves msg.sender). Fill proceeds always go
    ///         to the controller, so an operator can list but never
    ///         redirect.
    function setAsk(
        mapping(uint256 => Request) storage queue,
        mapping(uint256 => uint32) storage askPlusOne,
        mapping(address => mapping(address => bool)) storage isOperator,
        uint256 requestId,
        uint256 queueTail_,
        uint32 askBps,
        uint32 maxAskBps
    ) public {
        if (requestId >= queueTail_) revert InvalidRequestId();
        Request storage r = queue[requestId];
        address controller = r.user;
        if (controller == address(0)) revert RequestNotActive();
        if (msg.sender != controller && !isOperator[controller][msg.sender])
            revert NotRequestOwner();
        if (askBps == CLEAR_ASK) {
            if (askPlusOne[requestId] == 0) return;
            delete askPlusOne[requestId];
            emit FillAskCleared(requestId);
            return;
        }
        if (askBps > maxAskBps) revert AskTooHigh();
        if (r.bilAmount == r.bilSettled) revert NothingPending();
        askPlusOne[requestId] = askBps + 1;
        emit FillAskSet(requestId, controller, askBps);
    }

    /// @notice Cancel the still-unsettled portion of a redemption request.
    ///         Auth: controller or approved ERC-7540 operator. Clears any
    ///         fill listing, shrinks the entry to its settled portion (or
    ///         deletes it entirely when nothing is settled) and sweeps the
    ///         queue head. The vault applies `unsettled` to totalQueuedBil
    ///         and refunds the escrowed hDCL to `controller`.
    function cancel(
        mapping(uint256 => Request) storage queue,
        mapping(uint256 => uint32) storage askPlusOne,
        mapping(address => mapping(address => bool)) storage isOperator,
        uint256 requestId,
        uint256 queueHead_,
        uint256 queueTail_
    ) public returns (uint256 newQueueHead, address controller, uint256 unsettled) {
        if (requestId >= queueTail_) revert InvalidRequestId();
        Request storage request = queue[requestId];
        controller = request.user;
        if (controller == address(0)) revert RequestNotActive();
        if (msg.sender != controller && !isOperator[controller][msg.sender])
            revert NotRequestOwner();

        // A cancelled request must never remain fillable.
        if (askPlusOne[requestId] != 0) {
            delete askPlusOne[requestId];
            emit FillAskCleared(requestId);
        }

        newQueueHead = queueHead_;
        unsettled = request.bilAmount - request.bilSettled;
        if (unsettled > 0) {
            request.bilAmount = request.bilSettled; // shrink to settled portion
            emit RedemptionCancelled(requestId, unsettled);
        }

        // If nothing was settled, the request has nothing left — delete it
        // and try to compact the queue head. Sweep bounded so the
        // canceller's gas stays bounded even with many head holes.
        if (request.bilSettled == 0) {
            delete queue[requestId];
            if (requestId == queueHead_) {
                newQueueHead = advanceQueueHead(
                    queue,
                    queueHead_,
                    queueTail_,
                    MAX_FILL_ITERATIONS
                );
            }
        }
    }

    /// @notice Strict-FIFO fill: spend up to `budget` of msg.sender's
    ///         HOLLAR buying the pending portions of listed requests,
    ///         head-first, paying each controller directly. Mutates queue
    ///         entries and asks, then executes all payment legs (CEI within
    ///         the call); the vault applies `bilFilled` to `totalQueuedBil`,
    ///         stores `newQueueHead`, and releases the escrowed hDCL. Never
    ///         touches settled state (`bilSettled`/`hollarOwed`) — a fill
    ///         is a cancel with a different share destination, not a
    ///         settlement.
    ///
    ///         Skip semantics: holes and pending-zero entries advance the
    ///         head while co-located (same rules as processQueue). Live
    ///         entries that are unlisted — or ask a smaller discount than
    ///         the filler's `minAskBps` — are skipped WITHOUT head advance:
    ///         the head must never pass a live entry, and an aggressive ask
    ///         only prices out its own entry, never the queue behind it.
    function executeFill(
        mapping(uint256 => Request) storage queue,
        mapping(uint256 => uint32) storage askPlusOne,
        IERC20 hollar,
        uint256 queueHead_,
        uint256 queueTail_,
        uint256 budget,
        uint256 minAskBps,
        uint256 rate
    )
        public
        returns (
            uint256 newQueueHead,
            uint256 hollarSpent,
            uint256 bilFilled,
            uint256 count
        )
    {
        // Bound the budget so the share arithmetic (budget × WAD_ × BPS)
        // cannot overflow on adversarial input.
        if (budget > type(uint128).max) budget = type(uint128).max;

        newQueueHead = queueHead_;
        FillPay[] memory pays = new FillPay[](MAX_FILL_ITERATIONS);

        uint256 cursor = queueHead_;
        uint256 skips;

        while (cursor < queueTail_ && count < MAX_FILL_ITERATIONS && skips < MAX_FILL_SKIPS) {
            Request storage r = queue[cursor];

            if (r.user == address(0) || r.bilSettled == r.bilAmount) {
                // Hole, or nothing pending (fully settled / fully filled
                // earlier) — passable; settled entries stay in the mapping
                // for claim walkers. Advance head while co-located.
                if (cursor == newQueueHead) {
                    unchecked { newQueueHead++; }
                }
                unchecked { cursor++; skips++; }
                continue;
            }

            uint256 plusOne = askPlusOne[cursor];
            if (plusOne == 0 || plusOne - 1 < minAskBps) {
                // Live but not for sale (to this filler) — skip, NO head
                // advance. Co-location is broken from here on, so the head
                // naturally freezes before the first live entry.
                unchecked { cursor++; skips++; }
                continue;
            }

            if (budget == 0) break;

            uint256 ask = plusOne - 1;
            uint256 pending = r.bilAmount - r.bilSettled;
            address user = r.user; // hoisted: survives a delete below

            // Affordability decided in SHARES, not HOLLAR: with
            //   sharesAffordable = ⌊budget·wad·BPS / (rate·(BPS−ask))⌋
            // sharesAffordable ≥ pending ⟹ budget ≥ the double-floored
            // full price, so the full branch can never overdraw the budget
            // (deciding on the floored price has a 1-wei corner where the
            // clamped partial pay would exceed budget).
            uint256 sharesAffordable = (budget * WAD_ * BPS) / (rate * (BPS - ask));
            if (sharesAffordable == 0) break; // budget is dust — stop

            if (sharesAffordable >= pending) {
                // ── full fill ──
                uint256 pay = _fillPrice(pending, rate, ask);
                // Catastrophic-rate guard, mirrors processQueue: never
                // take shares for a zero payout.
                if (pay == 0) break;

                budget -= pay;
                r.bilAmount = r.bilSettled; // cancel-shrink of pending
                delete askPlusOne[cursor];
                emit FillAskCleared(cursor);
                if (r.bilSettled == 0) {
                    delete queue[cursor]; // becomes a hole
                }
                // Pending is now zero either way — passable.
                if (cursor == newQueueHead) {
                    unchecked { newQueueHead++; }
                }

                pays[count++] = FillPay(user, pay);
                hollarSpent += pay;
                bilFilled += pending;
                emit RequestFilled(cursor, user, pay, pending);
                unchecked { cursor++; }
            } else {
                // ── partial fill: budget exhausted on this entry ──
                uint256 pay = _fillPrice(sharesAffordable, rate, ask);
                if (pay == 0) break;

                r.bilAmount -= sharesAffordable; // pending shrinks in place; ask persists

                pays[count++] = FillPay(user, pay);
                hollarSpent += pay;
                bilFilled += sharesAffordable;
                emit RequestPartiallyFilled(cursor, user, pay, sharesAffordable);
                break;
            }
        }

        // Interactions after all state writes (CEI). HOLLAR has no transfer
        // hooks; the vault wraps this call in nonReentrant regardless.
        for (uint256 i; i < count; ++i) {
            hollar.safeTransferFrom(msg.sender, pays[i].controller, pays[i].amount);
        }
        if (count == 0) revert NothingFilled();
        emit QueueFilled(msg.sender, hollarSpent, bilFilled, count);
    }

    /// @dev Price of `shares` at `rate` discounted by `ask` bps. Double
    ///      floor, matching settlement's rounding direction (QueueLib
    ///      processQueue): sub-wei residue favors the payer (the filler).
    function _fillPrice(
        uint256 shares,
        uint256 rate,
        uint256 ask
    ) private pure returns (uint256) {
        return (((shares * rate) / WAD_) * (BPS - ask)) / BPS;
    }

    /// @notice Walk the controller's own settled requests, drawing down
    ///         bilSettled (and pro-rata hollarOwed) until `shares` is
    ///         exhausted. Reverts if the controller's total claimable is
    ///         less. Iteration is bounded by the controller's own activity —
    ///         immune to cancel-spam DoS that bloats queueTail.
    function claimByShares(
        mapping(uint256 => Request) storage queue,
        mapping(address => uint256[]) storage settledByController,
        address controller,
        uint256 shares
    ) public returns (uint256 assets) {
        uint256 remaining = shares;
        uint256[] storage ids = settledByController[controller];

        // Walk back-to-front so swap-pop never shifts not-yet-visited entries.
        uint256 j = ids.length;
        while (j > 0 && remaining > 0) {
            unchecked { --j; }
            uint256 i = ids[j];
            Request storage r = queue[i];

            if (r.user != controller || r.bilSettled == 0) {
                // Stale (cancelled hole / already drained) — evict and skip.
                _swapPop(ids, j);
                continue;
            }

            uint256 take = r.bilSettled <= remaining ? r.bilSettled : remaining;
            // Pro-rata of this request's locked HOLLAR
            uint256 hollarTake = (take * r.hollarOwed) / r.bilSettled;

            r.bilSettled -= take;
            r.hollarOwed -= hollarTake;
            r.bilAmount -= take;

            remaining -= take;
            assets += hollarTake;

            // Fully drained: nothing pending, nothing claimable → delete slot
            // AND evict from controller's index.
            if (r.bilAmount == 0) {
                delete queue[i];
                _swapPop(ids, j);
            } else if (r.bilSettled == 0) {
                // Nothing claimable left on this entry (only unsettled
                // remainder); remove from index.
                _swapPop(ids, j);
            }
        }

        if (remaining != 0) revert InsufficientClaimable();
    }

    /// @notice Walk the controller's own settled requests, drawing down
    ///         hollarOwed (and pro-rata bilSettled) until `assets` is
    ///         exhausted. Returns the share count consumed. Same DoS-safe
    ///         per-controller index pattern as claimByShares.
    function claimByAssets(
        mapping(uint256 => Request) storage queue,
        mapping(address => uint256[]) storage settledByController,
        address controller,
        uint256 assets
    ) public returns (uint256 shares, uint256 actualAssets) {
        uint256 remaining = assets;
        uint256[] storage ids = settledByController[controller];

        uint256 j = ids.length;
        while (j > 0 && remaining > 0) {
            unchecked { --j; }
            uint256 i = ids[j];
            Request storage r = queue[i];

            if (r.user != controller || r.hollarOwed == 0) {
                _swapPop(ids, j);
                continue;
            }

            uint256 take = r.hollarOwed <= remaining ? r.hollarOwed : remaining;
            // Pro-rata of this request's settled hDCL
            uint256 sharesTake = (take * r.bilSettled) / r.hollarOwed;

            r.hollarOwed -= take;
            r.bilSettled -= sharesTake;
            r.bilAmount -= sharesTake;

            remaining -= take;
            shares += sharesTake;
            actualAssets += take;

            if (r.bilAmount == 0) {
                delete queue[i];
                _swapPop(ids, j);
            } else if (r.bilSettled == 0) {
                _swapPop(ids, j);
            }
        }

        if (remaining != 0) revert InsufficientClaimable();
    }

    /// @dev Remove the entry at `idx` from `arr` in O(1) by swapping with
    ///      the last element and popping. Order within `arr` is not
    ///      preserved — fine here because claim walks are commutative.
    function _swapPop(uint256[] storage arr, uint256 idx) private {
        uint256 last = arr.length - 1;
        if (idx != last) arr[idx] = arr[last];
        arr.pop();
    }
}
