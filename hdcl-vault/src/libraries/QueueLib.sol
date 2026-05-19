// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title QueueLib
/// @notice FIFO redemption queue mechanics extracted from HDCLVault to keep
///         the vault under EIP-170. All three functions are `public` so they
///         deploy as a separate library contract and the vault DELEGATECALLs
///         them — saving ~3 KB on the vault's deployed bytecode.
/// @dev    Library functions do NOT touch `idleHollar` or `totalReservedHollar`
///         directly — those live on the vault. Library returns deltas; the
///         vault applies them. This keeps the storage write surface explicit
///         in the calling contract for audit clarity.
library QueueLib {
    /// @notice A queued redemption request.
    struct Request {
        address user;          // controller (= owner under standard flow)
        uint256 hdclAmount;    // total hDCL queued (decreases on cancel/claim)
        uint256 hdclSettled;   // rate-locked, ready to claim
        uint256 hollarOwed;    // HOLLAR reserved for the settled portion
    }

    error InsufficientClaimable();

    event RedemptionFulfilled(
        uint256 indexed requestId,
        address indexed user,
        uint256 hollarAmount,
        uint256 hdclBurned
    );
    event RedemptionPartiallyFulfilled(
        uint256 indexed requestId,
        address indexed user,
        uint256 hollarAmount,
        uint256 hdclBurned
    );

    /// @notice Settle pending requests in FIFO order using `available` HOLLAR
    ///         at the supplied `rate`. Locks HOLLAR into request.hollarOwed
    ///         and marks hdclSettled — but does NOT decrement vault-level
    ///         idleHollar or increment totalReservedHollar; the caller must
    ///         apply `hollarUsed` to those globals.
    /// @param queue           Storage ref to the redemption queue mapping
    /// @param queueHead_      Current queue head (will be advanced past
    ///                        cancelled holes / fully-settled entries)
    /// @param queueTail_      Current queue tail (loop bound)
    /// @param available       HOLLAR available to settle this batch
    /// @param rate            Current exchange rate (WAD-scaled)
    /// @param maxIterations   Cap on pending-entry settles per call
    /// @param maxSkips        Cap on cancelled/settled skips per call
    /// @param wad             1e18 (passed as arg to avoid library constant)
    /// @return newQueueHead   Updated queueHead
    /// @return hollarUsed     Total HOLLAR moved from idle into reserved
    /// @return hdclLocked     Total hDCL rate-locked across requests this call
    function processQueue(
        mapping(uint256 => Request) storage queue,
        uint256 queueHead_,
        uint256 queueTail_,
        uint256 available,
        uint256 rate,
        uint256 maxIterations,
        uint256 maxSkips,
        uint256 wad
    )
        public
        returns (uint256 newQueueHead, uint256 hollarUsed, uint256 hdclLocked)
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

            if (request.hdclSettled == request.hdclAmount) {
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

            uint256 pending = request.hdclAmount - request.hdclSettled;
            uint256 hollarValue = (pending * rate) / wad;

            // Catastrophic-rate guard: if rate has degraded so far that the
            // outstanding HDCL is worth zero HOLLAR, settling it would lock
            // value with no payout. Stop the loop — admin intervention is
            // needed before this entry can be safely processed.
            if (hollarValue == 0) break;

            if (available >= hollarValue) {
                // Fully settle — leave the entry in place for claim, but
                // advance queueHead/cursor past it.
                request.hdclSettled = request.hdclAmount;
                request.hollarOwed += hollarValue;

                hollarUsed += hollarValue;
                hdclLocked += pending;
                available -= hollarValue;

                emit RedemptionFulfilled(cursor, request.user, hollarValue, pending);

                if (cursor == newQueueHead) {
                    unchecked { newQueueHead++; }
                }
                unchecked { cursor++; }
            } else {
                // Partially settle
                uint256 hdclToSettle = (available * wad) / rate;
                if (hdclToSettle == 0) break; // Dust amount, stop

                // Lock only the HOLLAR equivalent of the rate-locked HDCL at
                // the current rate, not the full `available`. The truncation
                // residue (sub-wei vs `rate`) stays in idleHollar — it
                // benefits the vault, not the redeemer.
                uint256 hollarToReserve = (hdclToSettle * rate) / wad;

                request.hdclSettled += hdclToSettle;
                request.hollarOwed += hollarToReserve;

                hollarUsed += hollarToReserve;
                hdclLocked += hdclToSettle;
                available = 0;

                emit RedemptionPartiallyFulfilled(
                    cursor,
                    request.user,
                    hollarToReserve,
                    hdclToSettle
                );
                // Entry stays at cursor (more pending to settle next call).
                // Don't increment cursor — break out via available == 0 check.
            }
        }
    }

    /// @notice Walk the controller's settled requests in FIFO order, drawing
    ///         down hdclSettled (and pro-rata hollarOwed) until `shares` is
    ///         exhausted. Reverts if the controller's total claimable is less.
    /// @dev    Iterates from 0 because settled entries can live below queueHead
    ///         (queueHead tracks "first unprocessed", not "first unclaimed").
    function claimByShares(
        mapping(uint256 => Request) storage queue,
        uint256 queueTail_,
        address controller,
        uint256 shares
    ) public returns (uint256 assets) {
        uint256 remaining = shares;

        for (uint256 i = 0; i < queueTail_ && remaining > 0; i++) {
            Request storage r = queue[i];
            if (r.user != controller || r.hdclSettled == 0) continue;

            uint256 take = r.hdclSettled <= remaining ? r.hdclSettled : remaining;
            // Pro-rata of this request's locked HOLLAR
            uint256 hollarTake = (take * r.hollarOwed) / r.hdclSettled;

            r.hdclSettled -= take;
            r.hollarOwed -= hollarTake;
            r.hdclAmount -= take;

            remaining -= take;
            assets += hollarTake;

            // Fully drained: nothing pending, nothing claimable → delete.
            if (r.hdclAmount == 0) {
                delete queue[i];
            }
        }

        if (remaining != 0) revert InsufficientClaimable();
    }

    /// @notice Walk the controller's settled requests in FIFO order, drawing
    ///         down hollarOwed (and pro-rata hdclSettled) until `assets` is
    ///         exhausted. Returns the share count consumed.
    function claimByAssets(
        mapping(uint256 => Request) storage queue,
        uint256 queueTail_,
        address controller,
        uint256 assets
    ) public returns (uint256 shares, uint256 actualAssets) {
        uint256 remaining = assets;

        for (uint256 i = 0; i < queueTail_ && remaining > 0; i++) {
            Request storage r = queue[i];
            if (r.user != controller || r.hollarOwed == 0) continue;

            uint256 take = r.hollarOwed <= remaining ? r.hollarOwed : remaining;
            // Pro-rata of this request's settled hDCL
            uint256 sharesTake = (take * r.hdclSettled) / r.hollarOwed;

            r.hollarOwed -= take;
            r.hdclSettled -= sharesTake;
            r.hdclAmount -= sharesTake;

            remaining -= take;
            shares += sharesTake;
            actualAssets += take;

            if (r.hdclAmount == 0) {
                delete queue[i];
            }
        }

        if (remaining != 0) revert InsufficientClaimable();
    }
}
