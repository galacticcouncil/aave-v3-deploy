// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IBILVault
/// @notice Interface for the BIL Vault — a tokenized vault that wraps
///         Decentral Protocol lending positions into a fungible BIL token
///         with async redemption (ERC-7540 + ERC-4626 conformant).
interface IBILVault {
    // ──────────────────────────────────────────────
    //  Structs & Enums
    // ──────────────────────────────────────────────

    /// @notice Lifecycle states for a Decentral pool position NFT held by the vault.
    enum NFTState {
        Active,
        YieldWithdrawalRequested,
        YieldClaimed,
        PrincipalWithdrawalRequested,
        Redeemed
    }

    // ──────────────────────────────────────────────
    //  Events — vault-specific
    // ──────────────────────────────────────────────

    event Deposited(
        address indexed user,
        uint256 hollarAmount,
        uint256 bilMinted,
        uint256 tokenId
    );
    event RedemptionRequested(uint256 indexed requestId, address indexed user, uint256 bilAmount);
    event RedemptionCancelled(uint256 indexed requestId, uint256 bilReturned);
    event RedemptionFulfilled(uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 bilBurned);
    event RedemptionPartiallyFulfilled(
        uint256 indexed requestId,
        address indexed user,
        uint256 hollarAmount,
        uint256 bilBurned
    );
    event Reinvested(uint256 hollarAmount, uint256 tokenId);
    event PositionProcessed(uint256 indexed positionIndex, uint256 tokenId, uint8 newState);
    event PositionRedeemed(
        uint256 indexed positionIndex,
        uint256 tokenId,
        uint256 yieldReceived,
        uint256 principalReceived
    );
    event PrincipalMismatch(
        uint256 indexed positionIndex,
        uint256 indexed tokenId,
        uint256 expected,
        uint256 received,
        int256 delta
    );
    event DepositsPaused();
    event DepositsUnpaused();
    event TvlCapUpdated(uint256 newCap);
    event MinReinvestAmountUpdated(uint256 newAmount);
    event MinRedeemAmountUpdated(uint256 newAmount);
    event OracleUpdated(address indexed oracle);
    event PoolRegistered(address indexed pool);
    event ActiveDepositPoolSet(address indexed pool);
    event PoolRetired(address indexed pool);
    event AutoClaimSet(address indexed controller, bool enabled);

    // ──────────────────────────────────────────────
    //  ERC-4626 Deposit Side
    // ──────────────────────────────────────────────

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxMint(address receiver) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    // ──────────────────────────────────────────────
    //  ERC-7540 Async Redemption
    // ──────────────────────────────────────────────

    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);
    function cancelRedeem(uint256 requestId) external;
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);

    // ──────────────────────────────────────────────
    //  Operator + Auto-Claim
    // ──────────────────────────────────────────────

    function setOperator(address operator, bool approved) external;
    function isOperator(address controller, address operator) external view returns (bool);
    function setAutoClaim(bool enabled) external;
    function autoClaimEnabled(address controller) external view returns (bool);

    // ──────────────────────────────────────────────
    //  Permissionless Keeper Operations
    // ──────────────────────────────────────────────

    function pokeDecentral(uint256 positionIndex) external;
    function syncMaturities(uint256 maxPositions) external returns (uint256 processed);
    function pokeQueue() external;

    // ──────────────────────────────────────────────
    //  Vault-Specific Views
    // ──────────────────────────────────────────────

    function exchangeRate() external view returns (uint256);
    function getEstimatedWaitTime(uint256 requestId) external view returns (uint256);
    function getRedemptionRequest(uint256 requestId)
        external
        view
        returns (
            address user,
            uint256 bilAmount,
            uint256 bilSettled,
            uint256 hollarOwed,
            bool active
        );
    function getPosition(uint256 positionIndex)
        external
        view
        returns (
            uint256 tokenId,
            uint256 principal,
            uint256 apyWad,
            uint256 depositTime,
            uint256 maturityTime,
            uint8 state
        );
    function getPositionCount() external view returns (uint256);
    function getPositionHead() external view returns (uint256);
    function getTotalQueuedBil() external view returns (uint256);
    function getIdleHollar() external view returns (uint256);
    function getPoolCount() external view returns (uint256);
    function getOraclePrice() external view returns (uint256);

    // ──────────────────────────────────────────────
    //  Admin Functions
    // ──────────────────────────────────────────────

    function pauseDeposits() external;
    function unpauseDeposits() external;
    function pause() external;
    function unpause() external;
    function setTvlCap(uint256 newCap) external;
    function setMinReinvestAmount(uint256 amount) external;
    function setMinRedeemAmount(uint256 amount) external;
    function setOracle(address oracle) external;
    function registerPool(address pool) external;
    function setActiveDepositPool(address pool) external;
    function retirePool(address pool) external;
}
