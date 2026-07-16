// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IDecentralPool} from "../interfaces/IDecentralPool.sol";
import {IAggregatorV3Interface} from "../interfaces/IAggregatorV3Interface.sol";

/// @title QueueLib
/// @notice Shared BILVault mechanics deployed as a linked library to keep the
///         vault below EIP-170. Storage-bearing helpers receive each storage
///         reference explicitly; accounting helpers return aggregate deltas
///         for the vault to apply at the call boundary.
library QueueLib {

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

    error InsufficientClaimable();
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

    /// @notice Checkpoint up to `maxPositions` due positions starting at
    ///         `checkpointHead`, capping each one's yield at its maturity and
    ///         returning aggregate accounting deltas + the advanced head.
    /// @dev Positions are appended in non-decreasing maturity order (the vault
    ///      enforces this in `_addToBucket`), so a single monotonic
    ///      `checkpointHead` is the earliest un-checkpointed position — no heap
    ///      needed. Kept in the linked library so the loop does not consume the
    ///      vault's EIP-170 bytecode budget.
    function processMaturities(
        NFTPosition[] storage positions,
        uint256 checkpointHead,
        uint256 maxPositions,
        uint256 timestamp,
        uint256 rateSum,
        uint256 offsetSum,
        uint256 denominator
    )
        public
        returns (
            uint256 newHead,
            uint256 newRateSum,
            uint256 newOffsetSum,
            uint256 pendingYieldAdded
        )
    {
        newHead = checkpointHead;
        newRateSum = rateSum;
        newOffsetSum = offsetSum;
        uint256 len = positions.length;
        uint256 processed;
        while (processed < maxPositions && newHead < len) {
            NFTPosition storage pos = positions[newHead];
            // Earliest un-checkpointed position; stop once it isn't due yet.
            if (pos.maturityTime > timestamp) break;
            // Defensive: a position can only advance past Active after it has
            // been checkpointed, so this is normally false at the head.
            if (!pos.yieldCapped) {
                uint256 rate = pos.apyWad * pos.principal;
                uint256 capped = (rate *
                    (pos.maturityTime - pos.yieldStartTime)) / denominator;
                pos.pendingYield = capped;
                pos.yieldCapped = true;
                newRateSum -= rate;
                newOffsetSum -= rate * pos.yieldStartTime;
                pendingYieldAdded += capped;
                emit PositionYieldCapped(newHead, pos.maturityTime, capped);
            }
            unchecked {
                ++newHead;
                ++processed;
            }
        }
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
