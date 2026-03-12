// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IHDCLVault
/// @notice Interface for the HDCL Vault — a tokenized vault that wraps Decentral Protocol
///         lending positions into a fungible HDCL token with async redemption queue.
interface IHDCLVault {
    // ──────────────────────────────────────────────
    //  Structs & Enums
    // ──────────────────────────────────────────────

    /// @notice Lifecycle states for a Decentral pool position NFT held by the vault.
    /// @param Active                       Position is earning yield in the pool.
    /// @param YieldWithdrawalRequested      Yield withdrawal has been requested; awaiting execution.
    /// @param YieldClaimed                  Yield has been claimed; ready for principal withdrawal request.
    /// @param PrincipalWithdrawalRequested  Principal withdrawal has been requested; awaiting execution.
    /// @param Redeemed                      Position fully unwound; principal and yield recovered.
    enum NFTState {
        Active,
        YieldWithdrawalRequested,
        YieldClaimed,
        PrincipalWithdrawalRequested,
        Redeemed
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a user deposits stablecoins and receives HDCL tokens.
    /// @param user The depositor's address.
    /// @param hollarAmount The amount of stablecoins deposited.
    /// @param hdclMinted The amount of HDCL tokens minted to the user.
    /// @param decentalAmount The amount deployed into the Decentral pool.
    /// @param tokenId The Decentral pool position NFT ID created.
    event Deposited(
        address indexed user, uint256 hollarAmount, uint256 hdclMinted, uint256 decentalAmount, uint256 tokenId
    );

    /// @notice Emitted when part of a deposit is used to fulfill queued redemptions.
    /// @param hollarUsedForQueue The amount of stablecoins diverted to the redemption queue.
    /// @param hdclBurned The amount of HDCL burned to fulfill queued redemptions.
    event QueueClearedOnDeposit(uint256 hollarUsedForQueue, uint256 hdclBurned);

    /// @notice Emitted when a user submits a redemption request.
    /// @param requestId The unique ID of the redemption request.
    /// @param user The address requesting redemption.
    /// @param hdclAmount The amount of HDCL tokens submitted for redemption.
    event RedemptionRequested(uint256 indexed requestId, address indexed user, uint256 hdclAmount);

    /// @notice Emitted when a user cancels their pending redemption request.
    /// @param requestId The ID of the cancelled redemption request.
    /// @param hdclReturned The amount of HDCL tokens returned to the user.
    event RedemptionCancelled(uint256 indexed requestId, uint256 hdclReturned);

    /// @notice Emitted when a redemption request is fully fulfilled.
    /// @param requestId The ID of the fulfilled redemption request.
    /// @param user The address that received stablecoins.
    /// @param hollarAmount The amount of stablecoins paid out.
    /// @param hdclBurned The amount of HDCL burned.
    event RedemptionFulfilled(uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 hdclBurned);

    /// @notice Emitted when a redemption request is partially fulfilled.
    /// @param requestId The ID of the partially fulfilled redemption request.
    /// @param user The address that received a partial payout.
    /// @param hollarAmount The amount of stablecoins paid out so far.
    /// @param hdclBurned The amount of HDCL burned so far.
    event RedemptionPartiallyFulfilled(
        uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 hdclBurned
    );

    /// @notice Emitted when idle stablecoins are reinvested into a new Decentral pool position.
    /// @param hollarAmount The amount of stablecoins reinvested.
    /// @param tokenId The new Decentral pool position NFT ID.
    event Reinvested(uint256 hollarAmount, uint256 tokenId);

    /// @notice Emitted when a position is advanced to its next lifecycle state.
    /// @param positionIndex The index of the position in the vault's position array.
    /// @param tokenId The Decentral pool position NFT ID.
    /// @param newState The new NFTState value after processing.
    event PositionProcessed(uint256 indexed positionIndex, uint256 tokenId, uint8 newState);

    /// @notice Emitted when a position is fully redeemed and its funds recovered.
    /// @param positionIndex The index of the position in the vault's position array.
    /// @param tokenId The Decentral pool position NFT ID.
    /// @param yieldReceived The amount of yield recovered.
    /// @param principalReceived The amount of principal recovered.
    event PositionRedeemed(
        uint256 indexed positionIndex, uint256 tokenId, uint256 yieldReceived, uint256 principalReceived
    );

    /// @notice Emitted when an admin marks a position as stale (stuck or unresponsive).
    /// @param positionIndex The index of the stale position.
    event PositionMarkedStale(uint256 indexed positionIndex);

    /// @notice Emitted when an admin removes the stale mark from a position.
    /// @param positionIndex The index of the position no longer marked stale.
    event PositionUnmarkedStale(uint256 indexed positionIndex);

    /// @notice Emitted when deposits are paused by an admin.
    event DepositsPaused();

    /// @notice Emitted when deposits are unpaused by an admin.
    event DepositsUnpaused();

    /// @notice Emitted when the TVL cap is updated.
    /// @param newCap The new maximum total value locked in stablecoin decimals.
    event TvlCapUpdated(uint256 newCap);

    /// @notice Emitted when the minimum reinvestment amount is updated.
    /// @param newAmount The new minimum idle balance required before reinvestment.
    event MinReinvestAmountUpdated(uint256 newAmount);

    /// @notice Emitted when a position withdrawal is delayed.
    /// @param positionIndex The index of the delayed position.
    /// @param delaySeconds The delay duration in seconds.
    event WithdrawalDelayed(uint256 indexed positionIndex, uint256 delaySeconds);

    // ──────────────────────────────────────────────
    //  User Functions
    // ──────────────────────────────────────────────

    /// @notice Deposits stablecoins into the vault and mints HDCL tokens to the caller.
    /// @dev Caller must have approved the vault to spend `hollarAmount` of the stablecoin.
    ///      A portion of the deposit may be used to fulfill pending redemption requests.
    /// @param hollarAmount The amount of stablecoins to deposit.
    /// @return hdclMinted The amount of HDCL tokens minted to the caller.
    function deposit(uint256 hollarAmount) external returns (uint256 hdclMinted);

    /// @notice Submits a redemption request to exchange HDCL tokens for stablecoins.
    /// @dev The caller's HDCL is held by the vault until the request is fulfilled or cancelled.
    ///      Fulfillment is asynchronous and depends on position maturity and available liquidity.
    /// @param hdclAmount The amount of HDCL tokens to redeem.
    /// @return requestId The unique ID of the redemption request.
    function requestRedeem(uint256 hdclAmount) external returns (uint256 requestId);

    /// @notice Cancels a pending redemption request and returns HDCL to the caller.
    /// @dev Only the original requester can cancel. Partially fulfilled requests return
    ///      only the unfulfilled portion.
    /// @param requestId The ID of the redemption request to cancel.
    function cancelRedeem(uint256 requestId) external;

    // ──────────────────────────────────────────────
    //  Permissionless Operations
    // ──────────────────────────────────────────────

    /// @notice Advances a Decentral pool position through its withdrawal lifecycle.
    /// @dev Anyone can call this to progress a position from Active through to Redeemed.
    ///      Each call moves the position one step forward in the NFTState enum.
    /// @param positionIndex The index of the position in the vault's position array.
    function processPosition(uint256 positionIndex) external;

    /// @notice Processes the redemption queue using available idle stablecoins.
    /// @dev Anyone can call this. Iterates through pending redemption requests in FIFO order,
    ///      fulfilling them with idle stablecoins held by the vault.
    function processQueue() external;

    /// @notice Reinvests idle stablecoins into a new Decentral pool position.
    /// @dev Anyone can call this when the idle balance exceeds the minimum reinvest amount
    ///      and there are no pending redemption requests that should be fulfilled first.
    function reinvest() external;

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /// @notice Returns the total value of assets managed by the vault in stablecoin terms.
    /// @return The total assets denominated in stablecoin decimals.
    function totalAssets() external view returns (uint256);

    /// @notice Returns the current HDCL-to-stablecoin exchange rate as a WAD (1e18).
    /// @return The exchange rate where 1e18 represents a 1:1 ratio.
    function exchangeRate() external view returns (uint256);

    /// @notice Previews how many HDCL tokens would be minted for a given stablecoin deposit.
    /// @param hollarAmount The hypothetical stablecoin deposit amount.
    /// @return hdclAmount The estimated HDCL tokens that would be minted.
    function previewDeposit(uint256 hollarAmount) external view returns (uint256 hdclAmount);

    /// @notice Previews how many stablecoins would be received for a given HDCL redemption.
    /// @param hdclAmount The hypothetical HDCL amount to redeem.
    /// @return hollarAmount The estimated stablecoins that would be received.
    function previewRedeem(uint256 hdclAmount) external view returns (uint256 hollarAmount);

    /// @notice Returns the estimated wait time for a redemption request to be fulfilled.
    /// @param requestId The ID of the redemption request.
    /// @return estimatedSeconds The estimated time remaining in seconds until fulfillment.
    function getEstimatedWaitTime(uint256 requestId) external view returns (uint256 estimatedSeconds);

    /// @notice Returns the details of a redemption request.
    /// @param requestId The ID of the redemption request.
    /// @return user The address that submitted the request.
    /// @return hdclAmount The total HDCL amount requested for redemption.
    /// @return hdclFulfilled The amount of HDCL already fulfilled.
    /// @return active Whether the request is still active (not fully fulfilled or cancelled).
    function getRedemptionRequest(uint256 requestId)
        external
        view
        returns (address user, uint256 hdclAmount, uint256 hdclFulfilled, bool active);

    /// @notice Returns the details of a vault position.
    /// @param positionIndex The index of the position in the vault's position array.
    /// @return tokenId The Decentral pool position NFT ID.
    /// @return principal The stablecoin principal deposited into the position.
    /// @return apyWad The fixed APY at the time of deposit, WAD-scaled.
    /// @return depositTime The timestamp when the position was created.
    /// @return maturityTime The timestamp when the position matures.
    /// @return state The current NFTState of the position.
    function getPosition(uint256 positionIndex)
        external
        view
        returns (uint256 tokenId, uint256 principal, uint256 apyWad, uint256 depositTime, uint256 maturityTime, uint8 state);

    /// @notice Returns the total number of positions tracked by the vault.
    /// @return The position count (including redeemed positions).
    function getPositionCount() external view returns (uint256);

    /// @notice Returns the index of the oldest non-redeemed position.
    /// @return The head index of the active position window.
    function getPositionHead() external view returns (uint256);

    /// @notice Returns the total amount of HDCL queued for redemption.
    /// @return The total queued HDCL across all pending redemption requests.
    function getTotalQueuedHdcl() external view returns (uint256);

    /// @notice Returns the amount of idle stablecoins held by the vault.
    /// @dev Idle stablecoins are not deployed in any Decentral pool position.
    /// @return The idle stablecoin balance.
    function getIdleHollar() external view returns (uint256);

    // ──────────────────────────────────────────────
    //  Admin Functions
    // ──────────────────────────────────────────────

    /// @notice Pauses new deposits into the vault.
    /// @dev Restricted to admin role. Existing positions and redemptions are unaffected.
    function pauseDeposits() external;

    /// @notice Unpauses deposits, allowing new deposits into the vault.
    /// @dev Restricted to admin role.
    function unpauseDeposits() external;

    /// @notice Sets the maximum total value locked (TVL) cap for the vault.
    /// @dev Restricted to admin role. Deposits that would exceed this cap are rejected.
    /// @param newCap The new TVL cap in stablecoin decimals.
    function setTvlCap(uint256 newCap) external;

    /// @notice Sets the minimum idle stablecoin balance required before reinvestment.
    /// @dev Restricted to admin role. Prevents reinvesting amounts too small to be efficient.
    /// @param amount The new minimum reinvest amount in stablecoin decimals.
    function setMinReinvestAmount(uint256 amount) external;

    /// @notice Marks a position as stale, excluding it from normal processing.
    /// @dev Restricted to admin role. Used when a position is stuck or unresponsive
    ///      in the Decentral pool. Stale positions are skipped during automated processing.
    /// @param positionIndex The index of the position to mark as stale.
    function markPositionStale(uint256 positionIndex) external;

    /// @notice Removes the stale mark from a position, returning it to normal processing.
    /// @dev Restricted to admin role. Used when a previously stale position becomes responsive.
    /// @param positionIndex The index of the position to unmark.
    function unmarkPositionStale(uint256 positionIndex) external;
}
