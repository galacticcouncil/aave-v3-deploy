// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDecentralPool} from "./interfaces/IDecentralPool.sol";
import {IPoolToken} from "./interfaces/IPoolToken.sol";
import {IAggregatorV3Interface} from "./interfaces/IAggregatorV3Interface.sol";

/// @title HDCLVault
/// @notice Fungible yield-bearing ERC-20 wrapper around Decentral Protocol NFT positions.
/// @dev Single contract that is the ERC-20 token, vault logic, and Chainlink-compatible oracle.
///      Users deposit HOLLAR → vault deposits into Decentral → vault mints HDCL.
///      Exchange rate appreciates over time as yield accrues (non-rebasing model).
contract HDCLVault is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev Dead shares minted on first deposit to mitigate inflation attack
    uint256 private constant DEAD_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(0xdead);

    uint256 public constant MAX_QUEUE_ITERATIONS = 50;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ═══════════════════════════════════════════════════════════════════════
    //                          STRUCTS & ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    enum NFTState {
        Active,
        YieldWithdrawalRequested,
        YieldClaimed,
        PrincipalWithdrawalRequested,
        Redeemed
    }

    struct APYBucket {
        uint256 totalPrincipal;
        uint256 weightedYieldStart;
    }

    struct NFTPosition {
        uint256 tokenId;
        uint256 principal;
        uint256 apyWad;
        uint256 depositTime;
        uint256 maturityTime;
        uint256 yieldStartTime;
        NFTState state;
        bool isStale;
        uint256 stalePrincipal;
        uint256 staleYield;
        uint256 stateChangedAt;
    }

    struct RedemptionRequest {
        address user;
        uint256 hdclAmount;
        uint256 hdclFulfilled;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        IMMUTABLE-LIKE CONFIG
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Decentral lending pool contract
    IDecentralPool public decentralPool;
    /// @notice Decentral NFT contract
    IPoolToken public poolToken;
    /// @notice HOLLAR stablecoin
    IERC20 public hollar;

    // ═══════════════════════════════════════════════════════════════════════
    //                        MUTABLE CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Maximum total HOLLAR deposited
    uint256 public tvlCap;
    /// @notice Whether new deposits are accepted
    bool public depositsPaused;
    /// @notice Minimum HOLLAR for reinvestment
    uint256 public minReinvestAmount;
    /// @notice Minimum HDCL to request redemption
    uint256 public minRedeemAmount;
    /// @notice Time a position must be stuck in withdrawal-requested state before it can be marked stale
    uint256 public withdrawalDelay;
    /// @notice Chainlink-compatible oracle for wDCL/HOLLAR price
    IAggregatorV3Interface public oracle;

    // ═══════════════════════════════════════════════════════════════════════
    //                          ACCOUNTING STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice APY (WAD) → accounting bucket
    mapping(uint256 => APYBucket) public apyBuckets;
    /// @notice List of distinct APY values with non-zero totalPrincipal
    uint256[] public activeAPYList;
    /// @notice O(1) existence check for active APYs
    mapping(uint256 => bool) public isActiveAPY;
    /// @notice Sum of principal across all buckets
    uint256 public totalInvestedPrincipal;
    /// @notice Aggregate: sum(apyWad_i * totalPrincipal_i) for O(1) yield calc
    uint256 public yieldRateSum;
    /// @notice Aggregate: sum(apyWad_i * weightedYieldStart_i) for O(1) yield calc
    uint256 public yieldOffsetSum;
    /// @notice HOLLAR in vault available for queue fulfillment or reinvestment
    uint256 public idleHollar;
    /// @notice Sum of (stalePrincipal + staleYield) for stale positions
    uint256 public totalStaleValue;

    // ═══════════════════════════════════════════════════════════════════════
    //                       NFT POSITION TRACKING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice All NFT positions, ordered by deposit time
    NFTPosition[] public positions;
    /// @notice Index of the first non-redeemed position
    uint256 public positionHead;

    // ═══════════════════════════════════════════════════════════════════════
    //                         REDEMPTION QUEUE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice FIFO queue of pending redemptions
    mapping(uint256 => RedemptionRequest) public redemptionQueue;
    /// @notice Index of the first active (unfulfilled) request
    uint256 public queueHead;
    /// @notice Index of the next request to be created
    uint256 public queueTail;
    /// @notice Total HDCL across all active queue entries
    uint256 public totalQueuedHdcl;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Deposited(
        address indexed user,
        uint256 hollarAmount,
        uint256 hdclMinted,
        uint256 tokenId
    );
    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 hdclAmount
    );
    event RedemptionCancelled(uint256 indexed requestId, uint256 hdclReturned);
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
    event Reinvested(uint256 hollarAmount, uint256 tokenId);
    event PositionProcessed(
        uint256 indexed positionIndex,
        uint256 tokenId,
        uint8 newState
    );
    event PositionRedeemed(
        uint256 indexed positionIndex,
        uint256 tokenId,
        uint256 yieldReceived,
        uint256 principalReceived
    );
    event PositionMarkedStale(uint256 indexed positionIndex);
    event PositionUnmarkedStale(uint256 indexed positionIndex);
    event DepositsPaused();
    event DepositsUnpaused();
    event TvlCapUpdated(uint256 newCap);
    event MinReinvestAmountUpdated(uint256 newAmount);
    event MinRedeemAmountUpdated(uint256 newAmount);
    event OracleUpdated(address indexed oracle);
    event WithdrawalDelayUpdated(uint256 newDelay);
    event WithdrawalDelayed(
        uint256 indexed positionIndex,
        uint256 delaySeconds
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                            ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error DepositsArePaused();
    error ZeroAmount();
    error ExceedsTvlCap();
    error PositionAlreadyRedeemed();
    error PositionNotMature();
    error NotRequestOwner();
    error RequestNotActive();
    error InvalidRequestId();
    error QueueNotEmpty();
    error InsufficientIdleHollar();
    error PositionNotStale();
    error BelowMinimumRedeem();
    error PositionAlreadyStale();
    error PositionNotStuckLongEnough();

    // ═══════════════════════════════════════════════════════════════════════
    //                         INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault
    /// @param _decentralPool Decentral lending pool address
    /// @param _poolToken Decentral NFT contract address
    /// @param _hollar HOLLAR stablecoin address
    /// @param _tvlCap Maximum total HOLLAR deposited
    /// @param _withdrawalDelay Time (seconds) a position must be stuck before it can be marked stale
    /// @param _admin Governance admin address
    function initialize(
        address _decentralPool,
        address _poolToken,
        address _hollar,
        uint256 _tvlCap,
        uint256 _withdrawalDelay,
        address _admin
    ) external initializer {
        require(_decentralPool != address(0), "Zero decentralPool");
        require(_poolToken != address(0), "Zero poolToken");
        require(_hollar != address(0), "Zero hollar");
        require(_admin != address(0), "Zero admin");

        __ERC20_init("Hydrated Decentral", "HDCL");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        decentralPool = IDecentralPool(_decentralPool);
        poolToken = IPoolToken(_poolToken);
        hollar = IERC20(_hollar);
        tvlCap = _tvlCap;
        withdrawalDelay = _withdrawalDelay;
        minReinvestAmount = 10e18; // 10 HOLLAR
        minRedeemAmount = 1e18; // 1 HDCL

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       CORE ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total value of all vault assets in HOLLAR
    /// @return Total assets including invested principal, accrued yield, idle HOLLAR, and stale value
    function totalAssets() public view returns (uint256) {
        uint256 accruedYield = 0;
        if (yieldRateSum > 0) {
            uint256 gross = block.timestamp * yieldRateSum;
            if (gross > yieldOffsetSum) {
                accruedYield =
                    (gross - yieldOffsetSum) /
                    (SECONDS_PER_YEAR * WAD);
            }
        }
        return
            totalInvestedPrincipal +
            accruedYield +
            idleHollar +
            totalStaleValue;
    }

    /// @notice Current HDCL/HOLLAR exchange rate (18 decimals)
    /// @return Rate in WAD (1e18 = 1:1)
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        return (totalAssets() * WAD) / supply;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit HOLLAR and receive HDCL
    /// @param hollarAmount Amount of HOLLAR to deposit
    /// @return hdclMinted Amount of HDCL minted to caller
    function deposit(
        uint256 hollarAmount
    ) external nonReentrant whenNotPaused returns (uint256 hdclMinted) {
        if (depositsPaused) revert DepositsArePaused();
        if (hollarAmount == 0) revert ZeroAmount();
        if (totalAssets() + hollarAmount > tvlCap) revert ExceedsTvlCap();

        // Calculate HDCL to mint at current rate BEFORE any queue processing
        uint256 supply = totalSupply();
        if (supply == 0) {
            require(hollarAmount > DEAD_SHARES, "Deposit too small");
            hdclMinted = hollarAmount - DEAD_SHARES;
            hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
            _mint(DEAD_ADDRESS, DEAD_SHARES);
            _mint(msg.sender, hdclMinted);
        } else {
            uint256 assets = totalAssets();
            hdclMinted = (hollarAmount * supply) / assets;
            require(hdclMinted > 0, "Deposit too small");
            hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
            _mint(msg.sender, hdclMinted);
        }

        uint256 apyWad = getAPYWad();
        hollar.safeApprove(address(decentralPool), 0);
        hollar.safeApprove(address(decentralPool), hollarAmount);
        uint256 tokenId = decentralPool.deposit(hollarAmount);

        positions.push(
            NFTPosition({
                tokenId: tokenId,
                principal: hollarAmount,
                apyWad: apyWad,
                depositTime: block.timestamp,
                maturityTime: block.timestamp + _investmentPeriod(),
                yieldStartTime: block.timestamp,
                state: NFTState.Active,
                isStale: false,
                stalePrincipal: 0,
                staleYield: 0,
                stateChangedAt: block.timestamp
            })
        );

        _addToBucket(apyWad, hollarAmount, block.timestamp);

        emit Deposited(msg.sender, hollarAmount, hdclMinted, tokenId);
    }

    /// @notice Queue HDCL for redemption to HOLLAR
    /// @param hdclAmount Amount of HDCL to redeem
    /// @return requestId ID of the redemption request
    function requestRedeem(
        uint256 hdclAmount
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (hdclAmount < minRedeemAmount) revert BelowMinimumRedeem();

        // Escrow HDCL in the vault (not burned yet — _transfer reverts on insufficient balance)
        _transfer(msg.sender, address(this), hdclAmount);

        requestId = queueTail;
        redemptionQueue[requestId] = RedemptionRequest({
            user: msg.sender,
            hdclAmount: hdclAmount,
            hdclFulfilled: 0
        });
        queueTail++;
        totalQueuedHdcl += hdclAmount;

        emit RedemptionRequested(requestId, msg.sender, hdclAmount);
    }

    /// @notice Cancel a pending redemption request
    /// @param requestId ID of the request to cancel
    function cancelRedeem(uint256 requestId) external nonReentrant {
        if (requestId >= queueTail) revert InvalidRequestId();
        RedemptionRequest storage request = redemptionQueue[requestId];
        if (request.user == address(0)) revert RequestNotActive();
        if (request.user != msg.sender) revert NotRequestOwner();

        uint256 remaining = request.hdclAmount - request.hdclFulfilled;
        totalQueuedHdcl -= remaining;

        // Return escrowed HDCL
        _transfer(address(this), msg.sender, remaining);

        emit RedemptionCancelled(requestId, remaining);
        delete redemptionQueue[requestId];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    PERMISSIONLESS OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Advance a position through its Decentral withdrawal lifecycle
    /// @dev Callable by anyone (bot or user). Claims mature NFT yield/principal from Decentral.
    /// @param positionIndex Index in the positions array
    function pokeDecentral(
        uint256 positionIndex
    ) external nonReentrant whenNotPaused {
        NFTPosition storage pos = positions[positionIndex];
        if (pos.state == NFTState.Redeemed) revert PositionAlreadyRedeemed();

        // Active → YieldWithdrawalRequested
        if (
            pos.state == NFTState.Active && block.timestamp >= pos.maturityTime
        ) {
            decentralPool.requestYieldWithdrawal(pos.tokenId);
            pos.state = NFTState.YieldWithdrawalRequested;
            pos.stateChangedAt = block.timestamp;
            emit PositionProcessed(
                positionIndex,
                pos.tokenId,
                uint8(pos.state)
            );
        }

        // YieldWithdrawalRequested → YieldClaimed
        if (pos.state == NFTState.YieldWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            try decentralPool.executeYieldWithdrawal(pos.tokenId) {
                uint256 yieldReceived = hollar.balanceOf(address(this)) -
                    balBefore;
                _adjustBucketOnYieldClaim(pos);
                idleHollar += yieldReceived;
                // For stale positions: deduct only what actually arrived from totalStaleValue.
                // If Decentral paid less than the frozen estimate, keep the shortfall
                // in totalStaleValue to be reconciled at principal redemption.
                if (pos.isStale) {
                    uint256 staleYieldDeduction = pos.staleYield <=
                        yieldReceived
                        ? pos.staleYield
                        : yieldReceived;
                    totalStaleValue -= staleYieldDeduction;
                    pos.staleYield -= staleYieldDeduction;
                }
                pos.state = NFTState.YieldClaimed;
                pos.stateChangedAt = block.timestamp;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Not yet approved by Decentral — no-op, retry next cycle
                if (
                    block.timestamp - pos.stateChangedAt > 2 * withdrawalDelay
                ) {
                    emit WithdrawalDelayed(
                        positionIndex,
                        block.timestamp - pos.stateChangedAt
                    );
                }
                return;
            }
        }

        // YieldClaimed → PrincipalWithdrawalRequested
        if (pos.state == NFTState.YieldClaimed) {
            try decentralPool.requestPrincipalWithdrawal(pos.tokenId) {
                pos.state = NFTState.PrincipalWithdrawalRequested;
                pos.stateChangedAt = block.timestamp;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Decentral pool may be paused or broken — no-op, retry next cycle
                if (
                    block.timestamp - pos.stateChangedAt > 2 * withdrawalDelay
                ) {
                    emit WithdrawalDelayed(
                        positionIndex,
                        block.timestamp - pos.stateChangedAt
                    );
                }
                return;
            }
        }

        // PrincipalWithdrawalRequested → Redeemed
        if (pos.state == NFTState.PrincipalWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            try decentralPool.executePrincipalWithdrawal(pos.tokenId) {
                uint256 principalReceived = hollar.balanceOf(address(this)) -
                    balBefore;

                if (!pos.isStale) {
                    _adjustBucketOnPrincipalRedemption(pos);
                } else {
                    totalStaleValue -= (pos.stalePrincipal + pos.staleYield);
                }

                idleHollar += principalReceived;
                pos.state = NFTState.Redeemed;
                _advancePositionHead();

                emit PositionRedeemed(
                    positionIndex,
                    pos.tokenId,
                    0,
                    principalReceived
                );

                // Distribute available HOLLAR to queue
                if (totalQueuedHdcl > 0 && idleHollar > 0) {
                    uint256 rate = exchangeRate();
                    _processQueueWithHollar(idleHollar, rate);
                }
            } catch {
                // Not yet approved or delay not elapsed — no-op
                if (
                    block.timestamp - pos.stateChangedAt > 2 * withdrawalDelay
                ) {
                    emit WithdrawalDelayed(
                        positionIndex,
                        block.timestamp - pos.stateChangedAt
                    );
                }
                return;
            }
        }
    }

    /// @notice Process queued redemptions, then reinvest remaining idle HOLLAR
    /// @dev Callable by anyone (bot or user). Processes first MAX_QUEUE_ITERATIONS withdrawals,
    ///      then reinvests remaining idle HOLLAR if queue is empty.
    function pokeQueue() external nonReentrant whenNotPaused {
        // Step 1: Process pending redemptions (skip if dust can't burn even 1 HDCL)
        uint256 rate = exchangeRate();
        bool queueCanProgress = totalQueuedHdcl > 0 &&
            idleHollar > 0 &&
            (idleHollar * WAD) / rate > 0;

        if (queueCanProgress) {
            _processQueueWithHollar(idleHollar, rate);
        }

        // Step 2: Reinvest if queue is empty OR queue can't make progress
        if (
            !queueCanProgress &&
            idleHollar >= minReinvestAmount &&
            !depositsPaused
        ) {
            _reinvest();
        }
    }

    /// @dev Internal reinvest logic
    function _reinvest() internal {
        uint256 amount = idleHollar;

        // Early return if stale marking pushed sum past cap (prevents underflow)
        if (totalInvestedPrincipal + totalStaleValue >= tvlCap) return;

        // Respect TVL cap (including stale value)
        if (totalInvestedPrincipal + totalStaleValue + amount > tvlCap) {
            amount = tvlCap - totalInvestedPrincipal - totalStaleValue;
        }
        if (amount < minReinvestAmount) return;

        uint256 apyWad = getAPYWad();
        hollar.safeApprove(address(decentralPool), 0);
        hollar.safeApprove(address(decentralPool), amount);
        uint256 tokenId = decentralPool.deposit(amount);

        positions.push(
            NFTPosition({
                tokenId: tokenId,
                principal: amount,
                apyWad: apyWad,
                depositTime: block.timestamp,
                maturityTime: block.timestamp + _investmentPeriod(),
                yieldStartTime: block.timestamp,
                state: NFTState.Active,
                isStale: false,
                stalePrincipal: 0,
                staleYield: 0,
                stateChangedAt: block.timestamp
            })
        );

        _addToBucket(apyWad, amount, block.timestamp);
        idleHollar -= amount;

        emit Reinvested(amount, tokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Preview how much HDCL a HOLLAR deposit would mint
    function previewDeposit(
        uint256 hollarAmount
    ) external view returns (uint256 hdclAmount) {
        uint256 supply = totalSupply();
        if (supply == 0) return hollarAmount - DEAD_SHARES;
        return (hollarAmount * supply) / totalAssets();
    }

    /// @notice Preview the HOLLAR value of a HDCL redemption at current rate
    function previewRedeem(
        uint256 hdclAmount
    ) external view returns (uint256 hollarAmount) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (hdclAmount * totalAssets()) / supply;
    }

    /// @notice Get estimated wait time for a redemption request
    /// @return estimatedSeconds Seconds until expected full fulfillment
    function getEstimatedWaitTime(
        uint256 requestId
    ) external view returns (uint256 estimatedSeconds) {
        RedemptionRequest storage request = redemptionQueue[requestId];
        if (request.user == address(0)) return 0;

        uint256 rate = exchangeRate();

        // Sum total HOLLAR needed for all queue entries ahead of and including this request
        uint256 hollarNeeded = 0;
        for (uint256 i = queueHead; i <= requestId; i++) {
            RedemptionRequest storage r = redemptionQueue[i];
            if (r.user == address(0)) continue;
            uint256 remainingHdcl = r.hdclAmount - r.hdclFulfilled;
            hollarNeeded += (remainingHdcl * rate) / WAD;
        }

        // Subtract currently available idle HOLLAR
        if (idleHollar >= hollarNeeded) return 0;
        hollarNeeded -= idleHollar;

        // Walk through positions to find when enough matures
        uint256 accumulated = 0;
        for (uint256 i = positionHead; i < positions.length; i++) {
            NFTPosition storage pos = positions[i];
            if (pos.state == NFTState.Redeemed) continue;
            if (pos.isStale) continue;

            // Expected return: principal + yield
            uint256 expectedYield = (pos.principal *
                pos.apyWad *
                (pos.maturityTime - pos.yieldStartTime)) /
                (SECONDS_PER_YEAR * WAD);
            accumulated += pos.principal + expectedYield;

            if (accumulated >= hollarNeeded) {
                uint256 maturityWithDelay = pos.maturityTime +
                    _decentralWithdrawalDelay();
                if (maturityWithDelay > block.timestamp) {
                    return maturityWithDelay - block.timestamp;
                }
                return 0;
            }
        }

        // If we can't cover it with known positions, return max estimate
        return type(uint256).max;
    }

    /// @notice Get redemption request details
    function getRedemptionRequest(
        uint256 requestId
    )
        external
        view
        returns (
            address user,
            uint256 hdclAmount,
            uint256 hdclFulfilled,
            bool active
        )
    {
        RedemptionRequest storage r = redemptionQueue[requestId];
        return (r.user, r.hdclAmount, r.hdclFulfilled, r.user != address(0));
    }

    /// @notice Get NFT position details
    function getPosition(
        uint256 positionIndex
    )
        external
        view
        returns (
            uint256 tokenId,
            uint256 principal,
            uint256 apyWad,
            uint256 depositTime,
            uint256 maturityTime,
            uint8 state
        )
    {
        NFTPosition storage pos = positions[positionIndex];
        return (
            pos.tokenId,
            pos.principal,
            pos.apyWad,
            pos.depositTime,
            pos.maturityTime,
            uint8(pos.state)
        );
    }

    /// @notice Total number of positions (including redeemed)
    function getPositionCount() external view returns (uint256) {
        return positions.length;
    }

    /// @notice Index of the first non-redeemed position
    function getPositionHead() external view returns (uint256) {
        return positionHead;
    }

    /// @notice Total HDCL currently queued for redemption
    function getTotalQueuedHdcl() external view returns (uint256) {
        return totalQueuedHdcl;
    }

    /// @notice HOLLAR available for queue fulfillment or reinvestment
    function getIdleHollar() external view returns (uint256) {
        return idleHollar;
    }

    /// @notice Current fixed APY from the Decentral pool
    function getAPYWad() public view returns (uint256) {
        return decentralPool.fixedAPYWad();
    }

    /// @notice Number of active APY buckets
    function getActiveAPYCount() external view returns (uint256) {
        return activeAPYList.length;
    }

    /// @notice Get active APY at index
    function getActiveAPY(uint256 index) external view returns (uint256) {
        return activeAPYList[index];
    }

    /// @notice Total number of redemption requests ever created
    function getRedemptionQueueLength() external view returns (uint256) {
        return queueTail;
    }

    /// @notice Number of pending (unprocessed) queue entries
    function getRedemptionQueuePending() external view returns (uint256) {
        return queueTail - queueHead;
    }

    /// @notice Queue head index
    function getQueueHead() external view returns (uint256) {
        return queueHead;
    }

    /// @notice Get wDCL/HOLLAR price from the oracle, returned in 18 decimals
    function getOraclePrice() external view returns (uint256) {
        require(address(oracle) != address(0), "Oracle not set");
        (, int256 answer, , , ) = oracle.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        uint8 oracleDecimals = oracle.decimals();
        return (uint256(answer) * WAD) / (10 ** oracleDecimals);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Stop new deposits
    function pauseDeposits() external onlyRole(ADMIN_ROLE) {
        depositsPaused = true;
        emit DepositsPaused();
    }

    /// @notice Resume deposits
    function unpauseDeposits() external onlyRole(ADMIN_ROLE) {
        depositsPaused = false;
        emit DepositsUnpaused();
    }

    /// @notice Emergency pause — stops all state-changing operations
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume all operations
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Update TVL cap
    function setTvlCap(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        require(newCap >= totalAssets(), "Cap below current assets");
        tvlCap = newCap;
        emit TvlCapUpdated(newCap);
    }

    /// @notice Update minimum reinvestment threshold
    function setMinReinvestAmount(
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        minReinvestAmount = amount;
        emit MinReinvestAmountUpdated(amount);
    }

    /// @notice Update minimum redemption amount
    function setMinRedeemAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        minRedeemAmount = amount;
        emit MinRedeemAmountUpdated(amount);
    }

    /// @notice Set the oracle address
    function setOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        require(_oracle != address(0), "Zero address");
        oracle = IAggregatorV3Interface(_oracle);
        emit OracleUpdated(_oracle);
    }

    /// @notice Cap yield for a stuck position
    /// @dev Position must be in a withdrawal-requested state for longer than withdrawalDelay.
    ///      Removes from active yield calculation, freezes value at current level.
    function markPositionStale(
        uint256 positionIndex
    ) external onlyRole(ADMIN_ROLE) {
        NFTPosition storage pos = positions[positionIndex];
        if (pos.isStale) revert PositionAlreadyStale();
        if (pos.state == NFTState.Redeemed) revert PositionAlreadyRedeemed();

        // Guard: position must be stuck in a withdrawal-requested or yield-claimed state
        if (
            pos.state != NFTState.YieldWithdrawalRequested &&
            pos.state != NFTState.YieldClaimed &&
            pos.state != NFTState.PrincipalWithdrawalRequested
        ) revert PositionNotStuckLongEnough();
        if (block.timestamp - pos.stateChangedAt < withdrawalDelay)
            revert PositionNotStuckLongEnough();

        // Calculate current yield for this position.
        // For PrincipalWithdrawalRequested/YieldClaimed: yield was already claimed,
        // Decentral is no longer accruing yield — set to 0 to avoid phantom inflation.
        uint256 currentYield;
        if (
            pos.state == NFTState.PrincipalWithdrawalRequested ||
            pos.state == NFTState.YieldClaimed
        ) {
            currentYield = 0;
        } else {
            currentYield =
                (pos.principal *
                    pos.apyWad *
                    (block.timestamp - pos.yieldStartTime)) /
                (SECONDS_PER_YEAR * WAD);
        }

        // Remove from APY bucket
        _removeFromBucket(pos.apyWad, pos.principal, pos.yieldStartTime);

        // Record stale values
        pos.isStale = true;
        pos.stalePrincipal = pos.principal;
        pos.staleYield = currentYield;
        totalStaleValue += pos.principal + currentYield;

        emit PositionMarkedStale(positionIndex);
    }

    /// @notice Restore normal yield calculation for a position
    /// @param positionIndex Index of the stale position
    /// @param backtrackYield If true, preserves the pre-stale accrued yield by back-calculating
    ///        yieldStartTime. If false, resets yieldStartTime to now (yield accrued before
    ///        marking stale is forfeited from the exchange rate).
    function unmarkPositionStale(
        uint256 positionIndex,
        bool backtrackYield
    ) external onlyRole(ADMIN_ROLE) {
        NFTPosition storage pos = positions[positionIndex];
        if (!pos.isStale) revert PositionNotStale();

        // Remove from stale accounting
        totalStaleValue -= (pos.stalePrincipal + pos.staleYield);

        pos.isStale = false;

        if (
            backtrackYield &&
            pos.staleYield > 0 &&
            pos.principal > 0 &&
            pos.apyWad > 0
        ) {
            // Back-calculate yieldStartTime so the active formula reproduces staleYield:
            // staleYield = principal * apyWad * elapsed / (SECONDS_PER_YEAR * WAD)
            // elapsed = staleYield * SECONDS_PER_YEAR * WAD / (principal * apyWad)
            uint256 elapsed = (pos.staleYield * SECONDS_PER_YEAR * WAD) /
                (pos.principal * pos.apyWad);
            pos.yieldStartTime = block.timestamp - elapsed;
            _addToBucket(pos.apyWad, pos.principal, pos.yieldStartTime);
        } else {
            // Reset yield start to now — pre-stale yield is forfeited
            pos.yieldStartTime = block.timestamp;
            _addToBucket(pos.apyWad, pos.principal, block.timestamp);
        }

        pos.stalePrincipal = 0;
        pos.staleYield = 0;

        emit PositionUnmarkedStale(positionIndex);
    }

    /// @notice Update the withdrawal delay for stale marking
    function setWithdrawalDelay(
        uint256 _withdrawalDelay
    ) external onlyRole(ADMIN_ROLE) {
        withdrawalDelay = _withdrawalDelay;
        emit WithdrawalDelayUpdated(_withdrawalDelay);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ERC-721 RECEIVER
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accept NFTs from Decentral's _safeMint
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Process queue entries using available HOLLAR
    /// @param available HOLLAR available for distribution
    /// @param rate Current exchange rate (WAD)
    /// @return hollarUsed Total HOLLAR distributed
    /// @return hdclBurned Total HDCL burned from escrow
    function _processQueueWithHollar(
        uint256 available,
        uint256 rate
    ) internal returns (uint256 hollarUsed, uint256 hdclBurned) {
        uint256 iterations;
        while (
            available > 0 &&
            queueHead < queueTail &&
            iterations < MAX_QUEUE_ITERATIONS
        ) {
            iterations++;
            RedemptionRequest storage request = redemptionQueue[queueHead];

            if (request.user == address(0)) {
                queueHead++;
                continue;
            }

            uint256 remainingHdcl = request.hdclAmount - request.hdclFulfilled;
            uint256 hollarValue = (remainingHdcl * rate) / WAD;

            if (available >= hollarValue) {
                // Fully fulfill this request
                _burn(address(this), remainingHdcl);
                idleHollar -= hollarValue;
                hollar.safeTransfer(request.user, hollarValue);
                totalQueuedHdcl -= remainingHdcl;

                hollarUsed += hollarValue;
                hdclBurned += remainingHdcl;
                available -= hollarValue;

                emit RedemptionFulfilled(
                    queueHead,
                    request.user,
                    hollarValue,
                    remainingHdcl
                );
                delete redemptionQueue[queueHead];
                queueHead++;
            } else {
                // Partially fulfill
                uint256 hdclToBurn = (available * WAD) / rate;
                if (hdclToBurn == 0) break; // Dust amount, stop

                _burn(address(this), hdclToBurn);
                idleHollar -= available;
                hollar.safeTransfer(request.user, available);
                request.hdclFulfilled += hdclToBurn;
                totalQueuedHdcl -= hdclToBurn;

                emit RedemptionPartiallyFulfilled(
                    queueHead,
                    request.user,
                    available,
                    hdclToBurn
                );

                hollarUsed += available;
                hdclBurned += hdclToBurn;
                available = 0;
            }
        }
    }

    /// @dev Adjust APY bucket when yield is claimed from a position
    function _adjustBucketOnYieldClaim(NFTPosition storage pos) internal {
        if (pos.isStale) return; // Stale positions are not in active accounting

        APYBucket storage bucket = apyBuckets[pos.apyWad];
        uint256 oldStart = pos.principal * pos.yieldStartTime;
        uint256 newStart = pos.principal * block.timestamp;

        bucket.weightedYieldStart -= oldStart;
        bucket.weightedYieldStart += newStart;

        yieldOffsetSum -= pos.apyWad * oldStart;
        yieldOffsetSum += pos.apyWad * newStart;

        pos.yieldStartTime = block.timestamp;
    }

    /// @dev Adjust APY bucket when principal is redeemed from a position
    function _adjustBucketOnPrincipalRedemption(
        NFTPosition storage pos
    ) internal {
        _removeFromBucket(pos.apyWad, pos.principal, pos.yieldStartTime);
    }

    /// @dev Advance positionHead past redeemed positions
    function _advancePositionHead() internal {
        while (
            positionHead < positions.length &&
            positions[positionHead].state == NFTState.Redeemed
        ) {
            positionHead++;
        }
    }

    /// @dev Add principal to an APY bucket and update global accounting
    function _addToBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        _addToActiveAPYsIfNew(apyWad);
        apyBuckets[apyWad].totalPrincipal += principal;
        apyBuckets[apyWad].weightedYieldStart += principal * yieldStartTime;
        totalInvestedPrincipal += principal;

        yieldRateSum += apyWad * principal;
        yieldOffsetSum += apyWad * principal * yieldStartTime;
    }

    /// @dev Remove principal from an APY bucket and update global accounting
    function _removeFromBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        APYBucket storage bucket = apyBuckets[apyWad];
        bucket.totalPrincipal -= principal;
        bucket.weightedYieldStart -= principal * yieldStartTime;
        totalInvestedPrincipal -= principal;

        yieldRateSum -= apyWad * principal;
        yieldOffsetSum -= apyWad * principal * yieldStartTime;

        if (bucket.totalPrincipal == 0) {
            _removeFromActiveAPYs(apyWad);
        }
    }

    /// @dev Add an APY to activeAPYList if not already present
    function _addToActiveAPYsIfNew(uint256 apyWad) internal {
        if (isActiveAPY[apyWad]) return;
        isActiveAPY[apyWad] = true;
        activeAPYList.push(apyWad);
    }

    /// @dev Remove an APY from activeAPYList (swap-and-pop)
    function _removeFromActiveAPYs(uint256 apyWad) internal {
        if (!isActiveAPY[apyWad]) return;
        isActiveAPY[apyWad] = false;
        uint256 len = activeAPYList.length;
        for (uint256 i = 0; i < len; ) {
            if (activeAPYList[i] == apyWad) {
                activeAPYList[i] = activeAPYList[len - 1];
                activeAPYList.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Returns the minimum investment period from Decentral pool
    function _investmentPeriod() internal view returns (uint256) {
        return decentralPool.minimumInvestmentPeriodSeconds();
    }

    /// @dev Returns the principal withdrawal delay from Decentral pool
    function _decentralWithdrawalDelay() internal view returns (uint256) {
        return decentralPool.principalWithdrawalDelaySeconds();
    }

    /// @dev Authorize UUPS upgrade — only UPGRADER_ROLE
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════
    //                         STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reserved storage slots for future upgrades.
    uint256[50] private __gap;
}
