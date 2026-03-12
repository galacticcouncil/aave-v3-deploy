// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
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

    uint256 public constant INVESTMENT_PERIOD = 60 days;
    uint256 public constant WITHDRAWAL_DELAY = 48 hours;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev Dead shares minted on first deposit to mitigate inflation attack
    uint256 private constant DEAD_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(0xdead);

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
    }

    struct RedemptionRequest {
        address user;
        uint256 hdclAmount;
        uint256 hdclFulfilled;
        bool active;
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

    // ═══════════════════════════════════════════════════════════════════════
    //                          ACCOUNTING STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice APY (WAD) → accounting bucket
    mapping(uint256 => APYBucket) public apyBuckets;
    /// @notice List of distinct APY values with non-zero totalPrincipal
    uint256[] public activeAPYs;
    /// @notice Sum of principal across all buckets
    uint256 public totalInvestedPrincipal;
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
    RedemptionRequest[] public redemptionQueue;
    /// @notice Index of the first active (unfulfilled) request
    uint256 public queueHead;
    /// @notice Total HDCL across all active queue entries
    uint256 public totalQueuedHdcl;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Deposited(
        address indexed user,
        uint256 hollarAmount,
        uint256 hdclMinted,
        uint256 decentalAmount,
        uint256 tokenId
    );
    event QueueClearedOnDeposit(uint256 hollarUsedForQueue, uint256 hdclBurned);
    event RedemptionRequested(uint256 indexed requestId, address indexed user, uint256 hdclAmount);
    event RedemptionCancelled(uint256 indexed requestId, uint256 hdclReturned);
    event RedemptionFulfilled(
        uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 hdclBurned
    );
    event RedemptionPartiallyFulfilled(
        uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 hdclBurned
    );
    event Reinvested(uint256 hollarAmount, uint256 tokenId);
    event PositionProcessed(uint256 indexed positionIndex, uint256 tokenId, uint8 newState);
    event PositionRedeemed(
        uint256 indexed positionIndex, uint256 tokenId, uint256 yieldReceived, uint256 principalReceived
    );
    event PositionMarkedStale(uint256 indexed positionIndex);
    event PositionUnmarkedStale(uint256 indexed positionIndex);
    event DepositsPaused();
    event DepositsUnpaused();
    event TvlCapUpdated(uint256 newCap);
    event MinReinvestAmountUpdated(uint256 newAmount);
    event WithdrawalDelayed(uint256 indexed positionIndex, uint256 delaySeconds);

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
    error QueueNotEmpty();
    error InsufficientIdleHollar();
    error PositionNotStale();
    error PositionAlreadyStale();

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
    /// @param _admin Governance admin address
    function initialize(
        address _decentralPool,
        address _poolToken,
        address _hollar,
        uint256 _tvlCap,
        address _admin
    ) external initializer {
        __ERC20_init("Hydrated Decentral", "HDCL");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        decentralPool = IDecentralPool(_decentralPool);
        poolToken = IPoolToken(_poolToken);
        hollar = IERC20(_hollar);
        tvlCap = _tvlCap;
        minReinvestAmount = 10e18; // 10 HOLLAR

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        // Max approve HOLLAR to Decentral for gas efficiency
        hollar.approve(address(decentralPool), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       CORE ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total value of all vault assets in HOLLAR
    /// @return Total assets including invested principal, accrued yield, idle HOLLAR, and stale value
    function totalAssets() public view returns (uint256) {
        uint256 accruedYield = 0;
        uint256 len = activeAPYs.length;
        for (uint256 i = 0; i < len;) {
            uint256 apyWad = activeAPYs[i];
            APYBucket storage bucket = apyBuckets[apyWad];
            // yield = apyWad * (now * totalPrincipal - weightedYieldStart) / (SECONDS_PER_YEAR * 1e18)
            uint256 nowTimesPrincipal = block.timestamp * bucket.totalPrincipal;
            if (nowTimesPrincipal > bucket.weightedYieldStart) {
                accruedYield +=
                    apyWad * (nowTimesPrincipal - bucket.weightedYieldStart) / (SECONDS_PER_YEAR * 1e18);
            }
            unchecked {
                ++i;
            }
        }
        return totalInvestedPrincipal + accruedYield + idleHollar + totalStaleValue;
    }

    /// @notice Current HDCL/HOLLAR exchange rate (18 decimals)
    /// @return Rate in WAD (1e18 = 1:1)
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return totalAssets() * 1e18 / supply;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit HOLLAR and receive HDCL
    /// @param hollarAmount Amount of HOLLAR to deposit
    /// @return hdclMinted Amount of HDCL minted to caller
    function deposit(uint256 hollarAmount) external nonReentrant whenNotPaused returns (uint256 hdclMinted) {
        if (depositsPaused) revert DepositsArePaused();
        if (hollarAmount == 0) revert ZeroAmount();
        if (totalInvestedPrincipal + idleHollar + hollarAmount > tvlCap) revert ExceedsTvlCap();

        // Calculate HDCL to mint at current rate BEFORE any queue processing
        uint256 supply = totalSupply();
        if (supply == 0) {
            // First deposit: 1:1 rate, mint dead shares for inflation protection
            hdclMinted = hollarAmount - DEAD_SHARES;
            hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
            _mint(DEAD_ADDRESS, DEAD_SHARES);
            _mint(msg.sender, hdclMinted);
        } else {
            uint256 assets = totalAssets();
            hdclMinted = hollarAmount * supply / assets;
            hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
            _mint(msg.sender, hdclMinted);
        }

        // Track deposited HOLLAR in idleHollar so _processQueueWithHollar can
        // safely decrement it. Any portion not used for queue or DecentralPool
        // stays as idleHollar; portions invested are subtracted below.
        idleHollar += hollarAmount;

        // Clear redemption queue with deposit HOLLAR
        uint256 remaining = hollarAmount;
        uint256 hollarUsedForQueue = 0;
        uint256 hdclBurnedForQueue = 0;

        if (totalQueuedHdcl > 0) {
            uint256 rate = exchangeRate();
            (uint256 used, uint256 burned) = _processQueueWithHollar(remaining, rate);
            hollarUsedForQueue = used;
            hdclBurnedForQueue = burned;
            remaining -= used;
        }

        if (hollarUsedForQueue > 0) {
            emit QueueClearedOnDeposit(hollarUsedForQueue, hdclBurnedForQueue);
        }

        // Deposit remainder into Decentral
        uint256 tokenId = 0;
        uint256 decentalAmount = 0;

        if (remaining >= minReinvestAmount) {
            uint256 apyWad = decentralPool.fixedAPYWad();
            tokenId = decentralPool.deposit(remaining);
            decentalAmount = remaining;

            positions.push(
                NFTPosition({
                    tokenId: tokenId,
                    principal: remaining,
                    apyWad: apyWad,
                    depositTime: block.timestamp,
                    maturityTime: block.timestamp + INVESTMENT_PERIOD,
                    yieldStartTime: block.timestamp,
                    state: NFTState.Active,
                    isStale: false,
                    stalePrincipal: 0,
                    staleYield: 0
                })
            );

            _addToActiveAPYsIfNew(apyWad);
            apyBuckets[apyWad].totalPrincipal += remaining;
            apyBuckets[apyWad].weightedYieldStart += remaining * block.timestamp;
            totalInvestedPrincipal += remaining;
            idleHollar -= remaining; // Invested portion leaves idle
        }
        // else: remaining stays in idleHollar (already added above)

        emit Deposited(msg.sender, hollarAmount, hdclMinted, decentalAmount, tokenId);
    }

    /// @notice Queue HDCL for redemption to HOLLAR
    /// @param hdclAmount Amount of HDCL to redeem
    /// @return requestId ID of the redemption request
    function requestRedeem(uint256 hdclAmount) external nonReentrant returns (uint256 requestId) {
        if (hdclAmount == 0) revert ZeroAmount();
        require(balanceOf(msg.sender) >= hdclAmount, "Insufficient HDCL balance");

        // Escrow HDCL in the vault (not burned yet)
        _transfer(msg.sender, address(this), hdclAmount);

        requestId = redemptionQueue.length;
        redemptionQueue.push(
            RedemptionRequest({user: msg.sender, hdclAmount: hdclAmount, hdclFulfilled: 0, active: true})
        );
        totalQueuedHdcl += hdclAmount;

        emit RedemptionRequested(requestId, msg.sender, hdclAmount);
    }

    /// @notice Cancel a pending redemption request
    /// @param requestId ID of the request to cancel
    function cancelRedeem(uint256 requestId) external nonReentrant {
        RedemptionRequest storage request = redemptionQueue[requestId];
        if (request.user != msg.sender) revert NotRequestOwner();
        if (!request.active) revert RequestNotActive();

        uint256 remaining = request.hdclAmount - request.hdclFulfilled;
        request.active = false;
        totalQueuedHdcl -= remaining;

        // Return escrowed HDCL
        _transfer(address(this), msg.sender, remaining);

        emit RedemptionCancelled(requestId, remaining);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    PERMISSIONLESS OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Advance a position through its Decentral withdrawal lifecycle
    /// @param positionIndex Index in the positions array
    function processPosition(uint256 positionIndex) external nonReentrant {
        NFTPosition storage pos = positions[positionIndex];
        if (pos.state == NFTState.Redeemed) revert PositionAlreadyRedeemed();

        // Active → YieldWithdrawalRequested
        if (pos.state == NFTState.Active && block.timestamp >= pos.maturityTime) {
            decentralPool.requestYieldWithdrawal(pos.tokenId);
            pos.state = NFTState.YieldWithdrawalRequested;
            emit PositionProcessed(positionIndex, pos.tokenId, uint8(pos.state));
        }

        // YieldWithdrawalRequested → YieldClaimed
        if (pos.state == NFTState.YieldWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            try decentralPool.executeYieldWithdrawal(pos.tokenId) {
                uint256 yieldReceived = hollar.balanceOf(address(this)) - balBefore;
                _adjustBucketOnYieldClaim(pos);
                idleHollar += yieldReceived;
                pos.state = NFTState.YieldClaimed;
                emit PositionProcessed(positionIndex, pos.tokenId, uint8(pos.state));
            } catch {
                // Not yet approved by Decentral — no-op, retry next cycle
                return;
            }
        }

        // YieldClaimed → PrincipalWithdrawalRequested
        if (pos.state == NFTState.YieldClaimed) {
            decentralPool.requestPrincipalWithdrawal(pos.tokenId);
            pos.state = NFTState.PrincipalWithdrawalRequested;
            emit PositionProcessed(positionIndex, pos.tokenId, uint8(pos.state));
        }

        // PrincipalWithdrawalRequested → Redeemed
        if (pos.state == NFTState.PrincipalWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            try decentralPool.executePrincipalWithdrawal(pos.tokenId) {
                uint256 principalReceived = hollar.balanceOf(address(this)) - balBefore;

                if (!pos.isStale) {
                    _adjustBucketOnPrincipalRedemption(pos);
                } else {
                    // Stale position: adjust totalStaleValue with actual received
                    totalStaleValue -= (pos.stalePrincipal + pos.staleYield);
                }

                idleHollar += principalReceived;
                pos.state = NFTState.Redeemed;
                _advancePositionHead();

                emit PositionRedeemed(positionIndex, pos.tokenId, 0, principalReceived);

                // Distribute available HOLLAR to queue
                if (totalQueuedHdcl > 0 && idleHollar > 0) {
                    uint256 rate = exchangeRate();
                    _processQueueWithHollar(idleHollar, rate);
                }
            } catch {
                // Not yet approved or delay not elapsed — no-op
                return;
            }
        }
    }

    /// @notice Distribute available HOLLAR to queued redemption requests
    function processQueue() external nonReentrant {
        if (totalQueuedHdcl > 0 && idleHollar > 0) {
            uint256 rate = exchangeRate();
            _processQueueWithHollar(idleHollar, rate);
        }
    }

    /// @notice Reinvest idle HOLLAR into Decentral (only if queue is empty)
    function reinvest() external nonReentrant {
        if (totalQueuedHdcl > 0) revert QueueNotEmpty();
        if (idleHollar < minReinvestAmount) revert InsufficientIdleHollar();
        if (depositsPaused) revert DepositsArePaused();

        uint256 amount = idleHollar;

        // Respect TVL cap
        if (totalInvestedPrincipal + amount > tvlCap) {
            amount = tvlCap - totalInvestedPrincipal;
        }
        require(amount > 0, "Nothing to reinvest");

        uint256 apyWad = decentralPool.fixedAPYWad();
        uint256 tokenId = decentralPool.deposit(amount);

        positions.push(
            NFTPosition({
                tokenId: tokenId,
                principal: amount,
                apyWad: apyWad,
                depositTime: block.timestamp,
                maturityTime: block.timestamp + INVESTMENT_PERIOD,
                yieldStartTime: block.timestamp,
                state: NFTState.Active,
                isStale: false,
                stalePrincipal: 0,
                staleYield: 0
            })
        );

        _addToActiveAPYsIfNew(apyWad);
        apyBuckets[apyWad].totalPrincipal += amount;
        apyBuckets[apyWad].weightedYieldStart += amount * block.timestamp;
        totalInvestedPrincipal += amount;
        idleHollar -= amount;

        emit Reinvested(amount, tokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Preview how much HDCL a HOLLAR deposit would mint
    function previewDeposit(uint256 hollarAmount) external view returns (uint256 hdclAmount) {
        uint256 supply = totalSupply();
        if (supply == 0) return hollarAmount - DEAD_SHARES;
        return hollarAmount * supply / totalAssets();
    }

    /// @notice Preview the HOLLAR value of a HDCL redemption at current rate
    function previewRedeem(uint256 hdclAmount) external view returns (uint256 hollarAmount) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return hdclAmount * totalAssets() / supply;
    }

    /// @notice Get estimated wait time for a redemption request
    /// @return estimatedSeconds Seconds until expected full fulfillment
    function getEstimatedWaitTime(uint256 requestId) external view returns (uint256 estimatedSeconds) {
        RedemptionRequest storage request = redemptionQueue[requestId];
        if (!request.active) return 0;

        uint256 rate = exchangeRate();

        // Sum total HOLLAR needed for all queue entries ahead of and including this request
        uint256 hollarNeeded = 0;
        for (uint256 i = queueHead; i <= requestId; i++) {
            RedemptionRequest storage r = redemptionQueue[i];
            if (!r.active) continue;
            uint256 remainingHdcl = r.hdclAmount - r.hdclFulfilled;
            hollarNeeded += remainingHdcl * rate / 1e18;
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
            uint256 expectedYield =
                pos.principal * pos.apyWad * (pos.maturityTime - pos.yieldStartTime) / (SECONDS_PER_YEAR * 1e18);
            accumulated += pos.principal + expectedYield;

            if (accumulated >= hollarNeeded) {
                uint256 maturityWithDelay = pos.maturityTime + WITHDRAWAL_DELAY;
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
    function getRedemptionRequest(uint256 requestId)
        external
        view
        returns (address user, uint256 hdclAmount, uint256 hdclFulfilled, bool active)
    {
        RedemptionRequest storage r = redemptionQueue[requestId];
        return (r.user, r.hdclAmount, r.hdclFulfilled, r.active);
    }

    /// @notice Get NFT position details
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
        )
    {
        NFTPosition storage pos = positions[positionIndex];
        return (pos.tokenId, pos.principal, pos.apyWad, pos.depositTime, pos.maturityTime, uint8(pos.state));
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

    /// @notice Number of active APY buckets
    function getActiveAPYCount() external view returns (uint256) {
        return activeAPYs.length;
    }

    /// @notice Get active APY at index
    function getActiveAPY(uint256 index) external view returns (uint256) {
        return activeAPYs[index];
    }

    /// @notice Total number of redemption requests
    function getRedemptionQueueLength() external view returns (uint256) {
        return redemptionQueue.length;
    }

    /// @notice Queue head index
    function getQueueHead() external view returns (uint256) {
        return queueHead;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  ORACLE (AggregatorV3Interface)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice HDCL/HOLLAR price (18 decimals, matching ERC-20 decimals)
    /// @dev Implements Chainlink AggregatorV3Interface. Since ERC-20 decimals() returns 18,
    ///      the oracle answer is also in 18 decimals. If Aave requires 8 decimals,
    ///      deploy a thin HDCLOracle adapter contract.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (uint80(block.number), int256(exchangeRate()), block.timestamp, block.timestamp, uint80(block.number));
    }

    /// @notice Historical round data (returns same as latestRoundData since oracle is computed)
    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (uint80(block.number), int256(exchangeRate()), block.timestamp, block.timestamp, uint80(block.number));
    }

    /// @notice Oracle description
    function oracleDescription() external pure returns (string memory) {
        return "HDCL / HOLLAR";
    }

    /// @notice Oracle version
    function oracleVersion() external pure returns (uint256) {
        return 1;
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
        tvlCap = newCap;
        emit TvlCapUpdated(newCap);
    }

    /// @notice Update minimum reinvestment threshold
    function setMinReinvestAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        minReinvestAmount = amount;
        emit MinReinvestAmountUpdated(amount);
    }

    /// @notice Cap yield for a stuck position
    /// @dev Removes from active yield calculation, freezes value at current level
    function markPositionStale(uint256 positionIndex) external onlyRole(ADMIN_ROLE) {
        NFTPosition storage pos = positions[positionIndex];
        if (pos.isStale) revert PositionAlreadyStale();
        if (pos.state == NFTState.Redeemed) revert PositionAlreadyRedeemed();

        // Calculate current yield for this position
        uint256 currentYield = pos.principal * pos.apyWad * (block.timestamp - pos.yieldStartTime)
            / (SECONDS_PER_YEAR * 1e18);

        // Remove from APY bucket
        APYBucket storage bucket = apyBuckets[pos.apyWad];
        bucket.totalPrincipal -= pos.principal;
        bucket.weightedYieldStart -= pos.principal * pos.yieldStartTime;
        totalInvestedPrincipal -= pos.principal;

        if (bucket.totalPrincipal == 0) {
            _removeFromActiveAPYs(pos.apyWad);
        }

        // Record stale values
        pos.isStale = true;
        pos.stalePrincipal = pos.principal;
        pos.staleYield = currentYield;
        totalStaleValue += pos.principal + currentYield;

        emit PositionMarkedStale(positionIndex);
    }

    /// @notice Restore normal yield calculation for a position
    function unmarkPositionStale(uint256 positionIndex) external onlyRole(ADMIN_ROLE) {
        NFTPosition storage pos = positions[positionIndex];
        if (!pos.isStale) revert PositionNotStale();

        // Remove from stale accounting
        totalStaleValue -= (pos.stalePrincipal + pos.staleYield);

        // Restore to active yield calculation (reset yield start to now)
        pos.isStale = false;
        pos.yieldStartTime = block.timestamp;

        _addToActiveAPYsIfNew(pos.apyWad);
        apyBuckets[pos.apyWad].totalPrincipal += pos.principal;
        apyBuckets[pos.apyWad].weightedYieldStart += pos.principal * block.timestamp;
        totalInvestedPrincipal += pos.principal;

        pos.stalePrincipal = 0;
        pos.staleYield = 0;

        emit PositionUnmarkedStale(positionIndex);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ERC-721 RECEIVER
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accept NFTs from Decentral's _safeMint
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
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
    function _processQueueWithHollar(uint256 available, uint256 rate)
        internal
        returns (uint256 hollarUsed, uint256 hdclBurned)
    {
        while (available > 0 && queueHead < redemptionQueue.length) {
            RedemptionRequest storage request = redemptionQueue[queueHead];

            if (!request.active) {
                queueHead++;
                continue;
            }

            uint256 remainingHdcl = request.hdclAmount - request.hdclFulfilled;
            uint256 hollarValue = remainingHdcl * rate / 1e18;

            if (available >= hollarValue) {
                // Fully fulfill this request
                _burn(address(this), remainingHdcl);
                idleHollar -= hollarValue;
                hollar.safeTransfer(request.user, hollarValue);
                request.hdclFulfilled = request.hdclAmount;
                request.active = false;
                totalQueuedHdcl -= remainingHdcl;

                hollarUsed += hollarValue;
                hdclBurned += remainingHdcl;
                available -= hollarValue;

                emit RedemptionFulfilled(queueHead, request.user, hollarValue, remainingHdcl);
                queueHead++;
            } else {
                // Partially fulfill
                uint256 hdclToBurn = available * 1e18 / rate;
                if (hdclToBurn == 0) break; // Dust amount, stop

                _burn(address(this), hdclToBurn);
                idleHollar -= available;
                hollar.safeTransfer(request.user, available);
                request.hdclFulfilled += hdclToBurn;
                totalQueuedHdcl -= hdclToBurn;

                emit RedemptionPartiallyFulfilled(queueHead, request.user, available, hdclToBurn);

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
        // Remove old weighted yield start contribution
        bucket.weightedYieldStart -= pos.principal * pos.yieldStartTime;
        // Add new weighted yield start (reset to now)
        bucket.weightedYieldStart += pos.principal * block.timestamp;
        // Update position
        pos.yieldStartTime = block.timestamp;
    }

    /// @dev Adjust APY bucket when principal is redeemed from a position
    function _adjustBucketOnPrincipalRedemption(NFTPosition storage pos) internal {
        APYBucket storage bucket = apyBuckets[pos.apyWad];
        bucket.totalPrincipal -= pos.principal;
        bucket.weightedYieldStart -= pos.principal * pos.yieldStartTime;
        totalInvestedPrincipal -= pos.principal;

        if (bucket.totalPrincipal == 0) {
            _removeFromActiveAPYs(pos.apyWad);
        }
    }

    /// @dev Advance positionHead past redeemed positions
    function _advancePositionHead() internal {
        while (positionHead < positions.length && positions[positionHead].state == NFTState.Redeemed) {
            positionHead++;
        }
    }

    /// @dev Add an APY to activeAPYs if not already present
    function _addToActiveAPYsIfNew(uint256 apyWad) internal {
        uint256 len = activeAPYs.length;
        for (uint256 i = 0; i < len;) {
            if (activeAPYs[i] == apyWad) return;
            unchecked {
                ++i;
            }
        }
        activeAPYs.push(apyWad);
    }

    /// @dev Remove an APY from activeAPYs (swap-and-pop)
    function _removeFromActiveAPYs(uint256 apyWad) internal {
        uint256 len = activeAPYs.length;
        for (uint256 i = 0; i < len;) {
            if (activeAPYs[i] == apyWad) {
                activeAPYs[i] = activeAPYs[len - 1];
                activeAPYs.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Authorize UUPS upgrade — only UPGRADER_ROLE
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
