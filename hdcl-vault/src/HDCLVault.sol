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

    /// @dev Per-call cap on skipping cancelled (zero-address) queue entries.
    ///      Separate from the work cap so a wave of cancels doesn't starve real
    ///      redemptions of their per-call iteration budget. Bounded so a single
    ///      pokeQueue call cannot exceed the block gas limit even if the queue
    ///      contains an unbounded number of holes.
    uint256 public constant MAX_QUEUE_SKIPS = 500;

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
        // Yield amount Decentral has locked in for this position after the
        // requestYieldWithdrawal call but before executeYieldWithdrawal. While
        // the position is in YieldWithdrawalRequested, this is the deterministic
        // amount that will land in idleHollar at execute. The bucket is no
        // longer accruing yield for this position from request-time onward, so
        // pendingYield (plus totalPendingYield in totalAssets) keeps the
        // accounting flat across the admin-approval delay.
        uint256 pendingYield;
    }

    struct RedemptionRequest {
        address user;
        uint256 hdclAmount;
        uint256 hdclFulfilled;
        // Minimum HOLLAR-per-HDCL rate (WAD) the redeemer will accept. Set by
        // requestRedeem; bounded at submission to ≤ exchangeRate() so a
        // griefer cannot enqueue an unreachable floor. 0 = no floor.
        // Checked at fulfillment in _processQueueWithHollar; if the current
        // rate is below this floor, the entry is *parked* — left in place
        // and scanned past — so entries behind it can still be fulfilled.
        // The parked entry is re-evaluated on each subsequent call and
        // fulfills automatically once the rate recovers.
        uint256 minRateWad;
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

    /// @notice Cap on HOLLAR principal entering the protocol. Limits new
    ///         deposits and reinvestment of idle HOLLAR back into Decentral,
    ///         but does NOT cap accumulated yield. Existing positions continue
    ///         accruing yield even after the cap is reached, so `totalAssets()`
    ///         will routinely exceed `tvlCap` over the life of the protocol.
    ///         Integrators MUST NOT treat this as a hard ceiling on TVL — it
    ///         is a deposit-side rate-limit, not an invariant over total value.
    ///         The deposit check (`totalAssets() + hollarAmount > tvlCap`) and
    ///         the reinvest check (`totalInvestedPrincipal + totalStaleValue
    ///         + amount > tvlCap`) intentionally use different reference
    ///         quantities — both gate new principal but neither prevents yield
    ///         from inflating `totalAssets()` once existing positions are productive.
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
    /// @notice Sum of pendingYield across positions in YieldWithdrawalRequested
    ///         state. Tracks the yield Decentral has locked in but not yet paid;
    ///         keeps totalAssets() flat across the admin-approval delay.
    uint256 public totalPendingYield;

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
    /// @notice Emitted when a HOLLAR transfer to the redeemer reverts (e.g.,
    ///         a future HOLLAR blacklist freezes the recipient). The user's
    ///         escrowed HDCL is refunded, their request is removed from the
    ///         queue, and processing continues with the next entry — without
    ///         this, a single failing transfer would brick the entire queue.
    event RedemptionTransferFailed(
        uint256 indexed requestId,
        address indexed user,
        uint256 hollarAttempted,
        uint256 hdclRefunded
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
    /// @notice Emitted when Decentral's principal payout differs from the
    ///         recorded position principal. The delta is silently absorbed
    ///         (positive delta lifts idleHollar; negative delta is socialized
    ///         through a slightly lower exchange rate). Operators should monitor
    ///         this — repeated mismatches indicate a Decentral integration drift
    ///         (rounding, exit fee, surprise bonus payout) that warrants
    ///         investigation. `delta` = received - expected.
    event PrincipalMismatch(
        uint256 indexed positionIndex,
        uint256 indexed tokenId,
        uint256 expected,
        uint256 received,
        int256 delta
    );
    event PositionMarkedStale(uint256 indexed positionIndex);
    event PositionUnmarkedStale(uint256 indexed positionIndex);
    /// @notice Emitted when unmarkPositionStale writes off residual staleYield
    ///         on a position whose state has already advanced past
    ///         YieldWithdrawalRequested. The residual represents yield Decentral
    ///         underpaid in an earlier stale yield-execute; there is no HOLLAR
    ///         to recover, so it's absorbed into the exchange rate. Operators
    ///         should monitor this — repeated write-offs indicate an ongoing
    ///         Decentral integration drift.
    event StaleYieldShortfallWritten(
        uint256 indexed positionIndex,
        uint256 amount
    );
    /// @notice Emitted when pokeDecentral hits a stale-Active position. The
    ///         bucket bookkeeping for this position was already cleared at
    ///         mark-stale time, so resuming the Active → YWR transition here
    ///         would underflow the aggregates and double-count the yield
    ///         (it's already parked in totalStaleValue). The keeper-driven
    ///         lifecycle is paused for this position until admin runs
    ///         unmarkPositionStale to restore the bookkeeping.
    event PositionPokeSkippedStale(uint256 indexed positionIndex);
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
    error SlippageExceeded(uint256 expectedMin, uint256 actual);
    error SlippageFloorAboveCurrentRate(uint256 floor, uint256 currentRate);
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
    /// @return Total assets including invested principal, accrued yield, idle HOLLAR,
    ///         stale value, and pending-yield (locked amounts owed by Decentral).
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
            totalStaleValue +
            totalPendingYield;
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

    /// @notice Deposit HOLLAR and receive HDCL at the current rate.
    /// @dev    No slippage protection. For production integrations that need
    ///         to guard against rate movement between submission and execution,
    ///         use `depositSlippage(hollarAmount, minHdclOut)` instead.
    ///         (Two functions because the via_ir compiler hits a stack-too-deep
    ///         when deposit takes a second uint256 parameter together with all
    ///         the other state-touching helpers in this contract.)
    /// @param hollarAmount Amount of HOLLAR to deposit
    /// @return hdclMinted Amount of HDCL minted to caller
    function deposit(
        uint256 hollarAmount
    ) external nonReentrant whenNotPaused returns (uint256 hdclMinted) {
        hdclMinted = _previewMint(hollarAmount, 0);
        if (totalSupply() == 0) _mint(DEAD_ADDRESS, DEAD_SHARES);
        _mint(msg.sender, hdclMinted);
        hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
        uint256 tokenId = _depositIntoDecentral(hollarAmount);
        emit Deposited(msg.sender, hollarAmount, hdclMinted, tokenId);
    }

    /// @notice Deposit HOLLAR with slippage protection.
    /// @param hollarAmount Amount of HOLLAR to deposit
    /// @param minHdclOut Minimum HDCL the caller will accept; revert if the
    ///        rate would mint less. Use this for production integrations.
    /// @return hdclMinted Amount of HDCL minted to caller
    function depositSlippage(
        uint256 hollarAmount,
        uint256 minHdclOut
    ) external nonReentrant whenNotPaused returns (uint256 hdclMinted) {
        hdclMinted = _previewMint(hollarAmount, minHdclOut);
        if (totalSupply() == 0) _mint(DEAD_ADDRESS, DEAD_SHARES);
        _mint(msg.sender, hdclMinted);
        hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);
        uint256 tokenId = _depositIntoDecentral(hollarAmount);
        emit Deposited(msg.sender, hollarAmount, hdclMinted, tokenId);
    }

    /// @dev Forward HOLLAR to Decentral and record the new NFT position.
    ///      Extracted from `deposit` and `_reinvest` to keep their stack depths
    ///      shallow enough for via_ir compilation.
    function _depositIntoDecentral(uint256 amount) internal returns (uint256 tokenId) {
        uint256 apyWad = getAPYWad();
        hollar.safeApprove(address(decentralPool), 0);
        hollar.safeApprove(address(decentralPool), amount);
        tokenId = decentralPool.deposit(amount);

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
                stateChangedAt: block.timestamp,
                pendingYield: 0
            })
        );

        _addToBucket(apyWad, amount, block.timestamp);
    }

    /// @notice Queue HDCL for redemption to HOLLAR.
    /// @dev    The redeemer can optionally set `minRateWad` — the minimum
    ///         HOLLAR-per-HDCL rate (WAD) they'll accept. The floor is capped
    ///         at the current exchange rate at submission time: a floor
    ///         strictly above the current rate would never be reachable and
    ///         could be used to grief the queue, so submission reverts with
    ///         `SlippageFloorAboveCurrentRate`. At fulfillment time, if the
    ///         current rate is below the floor, the request is *parked* —
    ///         skipped without removal — until the rate recovers or the user
    ///         cancels. Pass 0 to disable the slippage check entirely.
    /// @param hdclAmount Amount of HDCL to redeem
    /// @param minRateWad Minimum acceptable rate (WAD); 0 = no floor. Must
    ///        be ≤ current exchange rate.
    /// @return requestId ID of the redemption request
    function requestRedeem(
        uint256 hdclAmount,
        uint256 minRateWad
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (hdclAmount < minRedeemAmount) revert BelowMinimumRedeem();

        // Submission-time floor cap. A floor strictly above the current rate
        // is unreachable by construction (the rate can only drop transiently
        // via stale-position write-offs or principal mismatch — it cannot be
        // commanded upward by a redeemer). Rejecting unreachable floors
        // closes the obvious DoS surface where an attacker would park an
        // entry that the queue could never satisfy.
        if (minRateWad > 0) {
            uint256 currentRate = exchangeRate();
            if (minRateWad > currentRate)
                revert SlippageFloorAboveCurrentRate(minRateWad, currentRate);
        }

        // Escrow HDCL in the vault (not burned yet — _transfer reverts on insufficient balance)
        _transfer(msg.sender, address(this), hdclAmount);

        requestId = queueTail;
        redemptionQueue[requestId] = RedemptionRequest({
            user: msg.sender,
            hdclAmount: hdclAmount,
            hdclFulfilled: 0,
            minRateWad: minRateWad
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

        // If we cancelled at the head, advance queueHead past this slot and any
        // immediately-following cancelled slots. This keeps the queue compact in
        // the common case (user cancels their own request at head) and reduces
        // work for downstream pokeQueue calls. Capped at MAX_QUEUE_ITERATIONS so
        // the canceller's gas cost stays bounded even if many holes are queued
        // in front; remaining holes will be cleaned up by pokeQueue's own skip
        // budget.
        if (requestId == queueHead) {
            uint256 head = queueHead;
            uint256 tail = queueTail;
            uint256 swept;
            while (
                head < tail &&
                swept < MAX_QUEUE_ITERATIONS &&
                redemptionQueue[head].user == address(0)
            ) {
                unchecked {
                    head++;
                    swept++;
                }
            }
            queueHead = head;
        }
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
            // Stale-Active gate. `markPositionStale` on an Active position
            // already calls `_removeYieldFromBucket` and `_removePrincipalFromBucket`
            // and parks the value in `totalStaleValue`. Re-running this branch's
            // success body would (a) call `_removeYieldFromBucket` a second
            // time, underflowing the aggregates if no other position absorbs
            // the subtraction (and the revert is inside the success block, so
            // try/catch below does NOT catch it), and (b) set `pos.pendingYield`
            // while `pos.staleYield` is still live in `totalStaleValue`,
            // double-counting the same yield in `totalAssets()`. The fix is
            // to pause the permissionless lifecycle for stale positions; admin
            // must call `unmarkPositionStale` to restore the bucket bookkeeping
            // (see `unmarkPositionStale`'s Active branch) before keeper
            // progression can resume.
            if (pos.isStale) {
                emit PositionPokeSkippedStale(positionIndex);
                return;
            }
            // Wrapped in try/catch like every other Decentral interaction in
            // this function — without it, a paused/shutdown Decentral pool at
            // a position's maturity would revert the whole call and leave the
            // position permanently stuck (markPositionStale used to reject
            // Active state; that guard has been relaxed below).
            try decentralPool.requestYieldWithdrawal(pos.tokenId) {
                // Decentral has now locked the yield amount Decentral will pay
                // at execute. Stop the bucket from accruing more yield for
                // this position from this point forward — anything beyond the
                // locked amount is yield Decentral will not pay. The locked
                // amount is tracked in pendingYield (and aggregated in
                // totalPendingYield) so totalAssets() stays flat across the
                // admin-approval delay.
                uint256 expected = (pos.principal *
                    pos.apyWad *
                    (block.timestamp - pos.yieldStartTime)) /
                    (SECONDS_PER_YEAR * WAD);
                pos.pendingYield = expected;
                totalPendingYield += expected;
                _removeYieldFromBucket(
                    pos.apyWad,
                    pos.principal,
                    pos.yieldStartTime
                );

                pos.state = NFTState.YieldWithdrawalRequested;
                pos.stateChangedAt = block.timestamp;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Decentral may be paused/shutdown — no-op so the position
                // stays Active. Admin can rescue via markPositionStale once
                // the position has been stuck past `withdrawalDelay`.
                if (
                    block.timestamp - pos.maturityTime > 2 * withdrawalDelay
                ) {
                    emit WithdrawalDelayed(
                        positionIndex,
                        block.timestamp - pos.maturityTime
                    );
                }
                return;
            }
        }

        // YieldWithdrawalRequested → YieldClaimed
        if (pos.state == NFTState.YieldWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            try decentralPool.executeYieldWithdrawal(pos.tokenId) {
                uint256 yieldReceived = hollar.balanceOf(address(this)) -
                    balBefore;

                // Bucket bookkeeping was already cleared at request time. Move
                // the locked yield from pending → idle. If pendingYield was
                // moved into staleValue when the position was marked stale
                // while in YWR, it's already 0 here and the stale branch below
                // handles the reconciliation via staleYield.
                if (pos.pendingYield > 0) {
                    totalPendingYield -= pos.pendingYield;
                    pos.pendingYield = 0;
                }
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

                // Surface any drift between the principal Decentral paid and what
                // the vault recorded. For non-stale positions, the expected
                // figure is the original deposit amount; for stale positions,
                // it's the principal frozen at stale-time. Mismatches are
                // silently absorbed into idleHollar (positive delta) or come
                // out of the exchange rate (negative delta) — the event lets
                // operators monitor for repeated drift without changing the
                // socialization behavior.
                uint256 expectedPrincipal = pos.isStale
                    ? pos.stalePrincipal
                    : pos.principal;
                if (principalReceived != expectedPrincipal) {
                    int256 delta = int256(principalReceived) -
                        int256(expectedPrincipal);
                    emit PrincipalMismatch(
                        positionIndex,
                        pos.tokenId,
                        expectedPrincipal,
                        principalReceived,
                        delta
                    );
                }

                if (!pos.isStale) {
                    _adjustBucketOnPrincipalRedemption(pos);
                } else {
                    // A residual `staleYield` here = Decentral underpaid in
                    // an earlier stale yield-execute (yieldReceived <
                    // staleYield). Reducing totalStaleValue by the full
                    // amount socializes the loss into the exchange rate.
                    // Surface it via the same event the admin-unmark path
                    // emits so monitoring catches keeper-driven write-offs
                    // too — otherwise this loss is invisible on-chain.
                    if (pos.staleYield > 0) {
                        emit StaleYieldShortfallWritten(
                            positionIndex,
                            pos.staleYield
                        );
                    }
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
    ///      then reinvests remaining idle HOLLAR if the queue couldn't progress.
    function pokeQueue() external nonReentrant whenNotPaused {
        uint256 rate = exchangeRate();

        // Always invoke the queue processor. With funds, it processes redemptions;
        // without funds, it still sweeps cancelled entries off the head, keeping
        // the queue compact in adversarial cancel-spam scenarios.
        (uint256 hollarUsed, ) = _processQueueWithHollar(idleHollar, rate);

        // Reinvest when the queue made no actual progress this call — i.e., we
        // didn't fulfill (or partial-fulfill) any entry. A purely-static
        // "queue has funds + entries" check would suppress reinvest whenever
        // the queue is wedged (every head entry parked behind an unmet floor,
        // or every recipient blacklisted), silently hoarding idle HOLLAR. Using
        // the actual progress signal frees those funds to earn yield until the
        // wedge clears (rate recovers / users cancel).
        if (
            hollarUsed == 0 &&
            idleHollar >= minReinvestAmount &&
            !depositsPaused
        ) {
            _reinvest();
        }
    }

    /// @dev Validate a deposit, compute the HDCL to mint at the current rate,
    ///      and enforce the slippage floor. Extracted from `deposit` to keep
    ///      that function's stack depth shallow enough for via_ir compilation.
    function _previewMint(uint256 hollarAmount, uint256 minHdclOut)
        internal
        view
        returns (uint256 hdclMinted)
    {
        if (depositsPaused) revert DepositsArePaused();
        if (hollarAmount == 0) revert ZeroAmount();
        if (totalAssets() + hollarAmount > tvlCap) revert ExceedsTvlCap();

        uint256 supply = totalSupply();
        if (supply == 0) {
            require(hollarAmount > DEAD_SHARES, "Deposit too small");
            hdclMinted = hollarAmount - DEAD_SHARES;
        } else {
            uint256 assets = totalAssets();
            // Catastrophic state: shares exist but no backing. Refuse to
            // deposit at a zero rate — the depositor would receive no HDCL
            // and lose their HOLLAR. Solidity 0.8+ would panic on the
            // division below; this gives a clear revert reason instead.
            require(assets > 0, "Vault has no assets");
            hdclMinted = (hollarAmount * supply) / assets;
            require(hdclMinted > 0, "Deposit too small");
        }
        if (hdclMinted < minHdclOut)
            revert SlippageExceeded(minHdclOut, hdclMinted);
    }

    /// @dev Internal reinvest logic. The cap check here uses the principal
    ///      components only — `totalInvestedPrincipal + totalStaleValue` —
    ///      not full `totalAssets()`. That's intentional and matches the
    ///      protocol's deposit-cap semantics (see `tvlCap` natspec): reinvest
    ///      only adds NEW principal to Decentral, so it should be limited by
    ///      the same "principal entering the system" rule as deposits, not
    ///      by inflated `totalAssets()` that includes already-accrued yield.
    function _reinvest() internal {
        uint256 amount = idleHollar;

        // Early return if stale marking pushed principal sum past cap (prevents underflow)
        if (totalInvestedPrincipal + totalStaleValue >= tvlCap) return;

        // Cap reinvestment so principal + stale doesn't exceed tvlCap. Yield
        // already in idleHollar / accruedYield / pendingYield is unaffected.
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
                stateChangedAt: block.timestamp,
                pendingYield: 0
            })
        );

        _addToBucket(apyWad, amount, block.timestamp);
        idleHollar -= amount;

        emit Reinvested(amount, tokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Preview how much HDCL a HOLLAR deposit would mint.
    /// @dev    Returns 0 for inputs that would revert in `deposit` (zero amount,
    ///         first-deposit dust below DEAD_SHARES). Lets off-chain callers
    ///         distinguish "would succeed with N HDCL" from "would revert"
    ///         without forcing them to catch a Solidity revert.
    function previewDeposit(
        uint256 hollarAmount
    ) external view returns (uint256 hdclAmount) {
        if (hollarAmount == 0) return 0;
        uint256 supply = totalSupply();
        if (supply == 0) {
            // Mirror deposit's `require(hollarAmount > DEAD_SHARES)`.
            if (hollarAmount <= DEAD_SHARES) return 0;
            return hollarAmount - DEAD_SHARES;
        }
        uint256 assets = totalAssets();
        // Catastrophic state (shares exist but no backing): deposit would
        // panic on division by zero. Mirror the deposit reject by returning
        // 0, so off-chain callers don't see an opaque panic.
        if (assets == 0) return 0;
        return (hollarAmount * supply) / assets;
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

            // Expected return: principal + yield. `yieldStartTime` can drift
            // *past* `maturityTime` after a long stale → unmark cycle on an
            // Active position: unmark sets yieldStartTime = block.timestamp −
            // elapsed (back-calculated from staleYield), and a long stale
            // duration pushes that result beyond the immutable maturityTime.
            // Without the clamp, the subtraction below underflows and reverts
            // this view for every redemption whose walk reaches this position,
            // bricking ETAs until the position fully redeems.
            uint256 yieldElapsed = pos.maturityTime > pos.yieldStartTime
                ? pos.maturityTime - pos.yieldStartTime
                : 0;
            uint256 expectedYield = (pos.principal *
                pos.apyWad *
                yieldElapsed) /
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

    /// @notice Get wDCL/HOLLAR price from the oracle, returned in 18 decimals.
    /// @dev    Defensive Chainlink-style checks. `WDCLOracle` is always-fresh
    ///         by construction, so these are mostly inert today, but
    ///         `setOracle` allows rotation to a heartbeat-style feed (e.g.,
    ///         Chainlink) where staleness becomes critical. Each check below
    ///         catches a documented Chainlink failure mode:
    ///           - `roundId != 0` — feed has been initialized
    ///           - `updatedAt > 0` — round actually completed
    ///           - `answeredInRound >= roundId` — answer isn't carry-over
    ///             from a prior round (stale data).
    function getOraclePrice() external view returns (uint256) {
        require(address(oracle) != address(0), "Oracle not set");
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        require(roundId != 0, "Invalid round ID");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price round");

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

    /// @notice Update the protocol's deposit cap (see `tvlCap` natspec).
    /// @dev    Requires `newCap >= totalAssets()` at the moment of the call.
    ///         This check guards against the operator stranding existing TVL
    ///         below the new ceiling — but it does NOT make `tvlCap` a true
    ///         TVL invariant, because yield accrual will then continue to push
    ///         `totalAssets()` above `newCap` over time. The cap continues to
    ///         restrict NEW principal entering via deposit/reinvest.
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

    /// @notice Update minimum redemption amount.
    /// @dev    Rejects `amount == 0`. A zero floor would let anyone post
    ///         zero-HDCL redemption requests that pass `requestRedeem`'s
    ///         `hdclAmount < minRedeemAmount` check, escrow zero HDCL,
    ///         and still consume one iteration of `_processQueueWithHollar`'s
    ///         work budget per spam entry — a cheap queue grief.
    function setMinRedeemAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Min must be positive");
        minRedeemAmount = amount;
        emit MinRedeemAmountUpdated(amount);
    }

    /// @notice Set the oracle address.
    /// @dev    Probes the candidate at set-time:
    ///         - `latestRoundData()` must respond with a positive `answer`
    ///           and a non-zero `updatedAt` (the feed is actually alive).
    ///         - `decimals()` must be in [6, 18] — bounded so `10 ** d`
    ///           in `getOraclePrice` can't overflow above 77 or inflate
    ///           the price ~1e8x at 0.
    ///         Catches fat-finger misconfiguration (wrong address, dead
    ///         feed, exotic decimals) before it can propagate to every
    ///         `getOraclePrice` consumer.
    function setOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        require(_oracle != address(0), "Zero address");

        IAggregatorV3Interface candidate = IAggregatorV3Interface(_oracle);
        (, int256 answer, , uint256 updatedAt, ) = candidate.latestRoundData();
        require(answer > 0, "Oracle: invalid answer");
        require(updatedAt > 0, "Oracle: zero updatedAt");
        uint8 d = candidate.decimals();
        require(d >= 6 && d <= 18, "Oracle: decimals out of range");

        oracle = candidate;
        emit OracleUpdated(_oracle);
    }

    /// @notice Cap yield for a stuck position.
    /// @dev    Allowed when the position is stuck in any post-deposit lifecycle
    ///         state (Active past maturity, YieldWithdrawalRequested,
    ///         YieldClaimed, or PrincipalWithdrawalRequested) for longer than
    ///         `withdrawalDelay`. The Active branch covers the case where
    ///         Decentral is paused/shutdown and pokeDecentral can't even
    ///         transition to YWR; without this branch the principal would be
    ///         permanently trapped.
    function markPositionStale(
        uint256 positionIndex
    ) external onlyRole(ADMIN_ROLE) {
        NFTPosition storage pos = positions[positionIndex];
        if (pos.isStale) revert PositionAlreadyStale();
        if (pos.state == NFTState.Redeemed) revert PositionAlreadyRedeemed();

        // State + delay guard. For each acceptable state, "stuck" is measured
        // from the time the position entered that state (stateChangedAt) — except
        // for Active, where we measure from maturityTime (the Active state itself
        // isn't "stuck" until the position has matured but pokeDecentral can't
        // advance it).
        uint256 stuckSince;
        if (pos.state == NFTState.Active) {
            if (block.timestamp < pos.maturityTime)
                revert PositionNotStuckLongEnough();
            stuckSince = pos.maturityTime;
        } else if (
            pos.state == NFTState.YieldWithdrawalRequested ||
            pos.state == NFTState.YieldClaimed ||
            pos.state == NFTState.PrincipalWithdrawalRequested
        ) {
            stuckSince = pos.stateChangedAt;
        } else {
            revert PositionNotStuckLongEnough();
        }
        if (block.timestamp - stuckSince < withdrawalDelay)
            revert PositionNotStuckLongEnough();

        // Calculate current yield for this position. The bookkeeping for yield
        // depends on lifecycle state:
        //   - Active: bucket is still accruing; compute owed yield up to now
        //     and remove from bucket.
        //   - YieldWithdrawalRequested: yield bookkeeping was already cleared
        //     at request time (totalPendingYield holds the locked amount).
        //     Move pendingYield → staleYield.
        //   - YieldClaimed / PrincipalWithdrawalRequested: yield was already
        //     paid by Decentral; pendingYield is 0 and bucket is clean.
        uint256 currentYield;
        if (pos.state == NFTState.Active) {
            currentYield =
                (pos.principal *
                    pos.apyWad *
                    (block.timestamp - pos.yieldStartTime)) /
                (SECONDS_PER_YEAR * WAD);
            _removeYieldFromBucket(
                pos.apyWad,
                pos.principal,
                pos.yieldStartTime
            );
        } else if (pos.state == NFTState.YieldWithdrawalRequested) {
            currentYield = pos.pendingYield;
            if (pos.pendingYield > 0) {
                totalPendingYield -= pos.pendingYield;
                pos.pendingYield = 0;
            }
            // No bucket-yield removal needed — already done at request time.
        } else {
            // YieldClaimed or PrincipalWithdrawalRequested
            currentYield = 0;
        }

        // Always remove principal — once stale, value moves to totalStaleValue.
        _removePrincipalFromBucket(pos.apyWad, pos.principal);

        // Record stale values
        pos.isStale = true;
        pos.stalePrincipal = pos.principal;
        pos.staleYield = currentYield;
        totalStaleValue += pos.principal + currentYield;

        emit PositionMarkedStale(positionIndex);
    }

    /// @notice Restore a stale position to normal accounting.
    /// @dev    Restoration semantics depend on the lifecycle state at unmark:
    ///         - Active: re-add yield bookkeeping with a back-calculated
    ///           yieldStartTime so the bucket reproduces staleYield. Position
    ///           resumes accruing.
    ///         - YieldWithdrawalRequested: restore pendingYield (Decentral's
    ///           locked amount); bucket stays cleared (no future accrual).
    ///         - YieldClaimed / PrincipalWithdrawalRequested: principal-only
    ///           restoration. Any residual staleYield > 0 means Decentral
    ///           underpaid in a stale yield-execute; that residual is a real
    ///           loss that gets written off. Emit `StaleYieldShortfallWritten`
    ///           so operators can see and investigate the loss.
    /// @param positionIndex Index of the stale position
    function unmarkPositionStale(
        uint256 positionIndex
    ) external onlyRole(ADMIN_ROLE) {
        NFTPosition storage pos = positions[positionIndex];
        if (!pos.isStale) revert PositionNotStale();
        // Guard: a position that was poked through to Redeemed while stale still has
        // isStale=true but is fully settled. Re-adding it to active accounting would
        // recreate phantom principal.
        if (pos.state == NFTState.Redeemed) revert PositionAlreadyRedeemed();

        // Remove from stale accounting
        totalStaleValue -= (pos.stalePrincipal + pos.staleYield);

        pos.isStale = false;

        // Always restore principal — Decentral still owes the principal until it's redeemed.
        _addPrincipalToBucket(pos.apyWad, pos.principal);

        if (pos.state == NFTState.Active) {
            // Re-add yield bookkeeping with back-calculated yieldStartTime so
            // the bucket reproduces staleYield exactly.
            if (pos.staleYield > 0 && pos.principal > 0 && pos.apyWad > 0) {
                uint256 elapsed = (pos.staleYield * SECONDS_PER_YEAR * WAD) /
                    (pos.principal * pos.apyWad);
                pos.yieldStartTime = block.timestamp - elapsed;
            } else {
                pos.yieldStartTime = block.timestamp;
            }
            _addYieldToBucket(pos.apyWad, pos.principal, pos.yieldStartTime);
        } else if (
            pos.state == NFTState.YieldWithdrawalRequested &&
            pos.staleYield > 0
        ) {
            // Decentral has the amount locked; restore as pending.
            pos.pendingYield = pos.staleYield;
            totalPendingYield += pos.staleYield;
        } else if (
            (pos.state == NFTState.YieldClaimed ||
                pos.state == NFTState.PrincipalWithdrawalRequested) &&
            pos.staleYield > 0
        ) {
            // Decentral already underpaid this position in a stale yield-execute
            // (yieldReceived < staleYield). The residual `staleYield` is a real
            // loss — there is no HOLLAR to recover and no Decentral promise to
            // pay it. Emit explicitly so operators see the write-off instead of
            // it being absorbed silently into the exchange rate.
            emit StaleYieldShortfallWritten(positionIndex, pos.staleYield);
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
    /// @dev    Only the configured `poolToken` contract may push NFTs to the
    ///         vault. Without this guard, anyone can transfer arbitrary NFTs
    ///         into the vault — no fund-impact path (position iteration uses
    ///         the `positions[]` array, not the held-NFT set) but storage and
    ///         event spam are real and cheap to prevent.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
        require(msg.sender == address(poolToken), "Only pool NFTs");
        return IERC721Receiver.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Process queue entries using available HOLLAR.
    ///      Uses two pointers:
    ///        - `queueHead`: lowest slot that is still active (parked entries
    ///          count as active — they hold their FIFO position so a transient
    ///          rate dip doesn't force the user to resubmit).
    ///        - `cursor`: the slot the loop is currently inspecting; may run
    ///          ahead of `queueHead` when scanning past parked entries.
    ///      `queueHead` only advances when the head slot itself is settled
    ///      (fulfilled, refunded, or already a cancelled hole). This is what
    ///      makes the slippage gate a *park* instead of a head-of-line block:
    ///      entries behind a parked one keep getting served.
    /// @param available HOLLAR available for distribution
    /// @param rate Current exchange rate (WAD)
    /// @return hollarUsed Total HOLLAR distributed
    /// @return hdclBurned Total HDCL burned from escrow
    function _processQueueWithHollar(
        uint256 available,
        uint256 rate
    ) internal returns (uint256 hollarUsed, uint256 hdclBurned) {
        uint256 iterations;
        uint256 skips;
        uint256 cursor = queueHead;

        while (
            cursor < queueTail &&
            iterations < MAX_QUEUE_ITERATIONS &&
            skips < MAX_QUEUE_SKIPS
        ) {
            RedemptionRequest storage request = redemptionQueue[cursor];

            if (request.user == address(0)) {
                // Cancelled hole — sweep past without consuming work budget.
                // Bounded by MAX_QUEUE_SKIPS to keep gas predictable under
                // mass cancellations. This sweep happens even with
                // `available == 0` so the queue can be cleaned without funds.
                // Advance queueHead only while it's still co-located with the
                // cursor — i.e., all holes encountered so far are at the head.
                if (cursor == queueHead) {
                    unchecked { queueHead++; }
                }
                unchecked { cursor++; skips++; }
                continue;
            }

            // Hit a real entry. Stop if there's no funds left.
            if (available == 0) break;

            // Slippage gate: park the entry instead of blocking the queue.
            // The entry stays at its slot (no delete, no head advance) so
            // future calls can re-evaluate against a recovered rate. Counted
            // toward the skip budget — not the iteration budget — because no
            // funds changed hands; this also bounds the gas a griefer can
            // burn even with the submission cap in place.
            if (request.minRateWad > 0 && rate < request.minRateWad) {
                unchecked { cursor++; skips++; }
                continue;
            }

            iterations++;

            uint256 remainingHdcl = request.hdclAmount - request.hdclFulfilled;
            uint256 hollarValue = (remainingHdcl * rate) / WAD;

            // Catastrophic-rate guard: if rate has degraded so far that the
            // outstanding HDCL is worth zero HOLLAR, burning it would extract
            // value from the user with no payout. Stop the loop here — admin
            // intervention is needed to investigate the rate before this entry
            // can be safely processed.
            if (hollarValue == 0) break;

            if (available >= hollarValue) {
                // Fully fulfill this request
                if (_tryHollarTransfer(request.user, hollarValue)) {
                    _burn(address(this), remainingHdcl);
                    idleHollar -= hollarValue;
                    totalQueuedHdcl -= remainingHdcl;

                    hollarUsed += hollarValue;
                    hdclBurned += remainingHdcl;
                    available -= hollarValue;

                    emit RedemptionFulfilled(
                        cursor,
                        request.user,
                        hollarValue,
                        remainingHdcl
                    );
                } else {
                    // HOLLAR transfer reverted (e.g., user got blacklisted).
                    // Refund escrowed HDCL, remove from queue; idleHollar
                    // untouched (no HOLLAR moved). Queue keeps moving.
                    _transfer(address(this), request.user, remainingHdcl);
                    totalQueuedHdcl -= remainingHdcl;
                    emit RedemptionTransferFailed(
                        cursor,
                        request.user,
                        hollarValue,
                        remainingHdcl
                    );
                }
                delete redemptionQueue[cursor];
                // Settled the head slot? Advance head with it. Otherwise we
                // leave a hole between queueHead and the next live entry;
                // it'll be swept by the cancelled-entry branch on a future
                // call (bounded by MAX_QUEUE_SKIPS).
                if (cursor == queueHead) {
                    unchecked { queueHead++; }
                }
                unchecked { cursor++; }
            } else {
                // Partially fulfill
                uint256 hdclToBurn = (available * WAD) / rate;
                if (hdclToBurn == 0) break; // Dust amount, stop

                // Pay out only the HOLLAR equivalent of the burned HDCL at the
                // current rate, not the full `available`. The truncation residue
                // (always sub-wei when measured against `rate`) stays in
                // idleHollar — it benefits the vault, not the redeemer.
                uint256 hollarToTransfer = (hdclToBurn * rate) / WAD;

                if (_tryHollarTransfer(request.user, hollarToTransfer)) {
                    _burn(address(this), hdclToBurn);
                    idleHollar -= hollarToTransfer;
                    request.hdclFulfilled += hdclToBurn;
                    totalQueuedHdcl -= hdclToBurn;

                    emit RedemptionPartiallyFulfilled(
                        cursor,
                        request.user,
                        hollarToTransfer,
                        hdclToBurn
                    );

                    hollarUsed += hollarToTransfer;
                    hdclBurned += hdclToBurn;
                    available = 0;
                    // Entry stays at `cursor` (not deleted). queueHead stays
                    // put. The available==0 check on the next iteration will
                    // break us out, leaving the partial entry for next call.
                } else {
                    // Transfer failed mid-partial. Refund the user's full
                    // outstanding HDCL escrow, remove from queue, and continue
                    // — `available` is untouched so the next entry can be tried.
                    uint256 refund = request.hdclAmount - request.hdclFulfilled;
                    _transfer(address(this), request.user, refund);
                    totalQueuedHdcl -= refund;
                    emit RedemptionTransferFailed(
                        cursor,
                        request.user,
                        hollarToTransfer,
                        refund
                    );
                    delete redemptionQueue[cursor];
                    if (cursor == queueHead) {
                        unchecked { queueHead++; }
                    }
                    unchecked { cursor++; }
                }
            }
        }
    }

    /// @dev Strip a position's principal contribution after Decentral has returned principal.
    ///      Yield bookkeeping was already cleared at yield claim — do not touch it here.
    function _adjustBucketOnPrincipalRedemption(
        NFTPosition storage pos
    ) internal {
        _removePrincipalFromBucket(pos.apyWad, pos.principal);
    }

    /// @dev Attempt a HOLLAR transfer; return false on revert or if the token
    ///      returns false. Used by `_processQueueWithHollar` so a single failing
    ///      recipient (e.g., a future HOLLAR blacklist) cannot brick the entire
    ///      FIFO queue. We call `transfer` directly (not safeTransfer) because
    ///      try/catch only works on external function calls — SafeERC20's
    ///      internal helper can't be wrapped. HOLLAR is a known, standards-
    ///      compliant ERC20, so the bool-return path is sufficient.
    function _tryHollarTransfer(address to, uint256 amount)
        internal
        returns (bool)
    {
        try hollar.transfer(to, amount) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
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

    /// @dev Add a position's principal to bucket + global accounting (no yield change).
    function _addPrincipalToBucket(
        uint256 apyWad,
        uint256 principal
    ) internal {
        _addToActiveAPYsIfNew(apyWad);
        apyBuckets[apyWad].totalPrincipal += principal;
        totalInvestedPrincipal += principal;
    }

    /// @dev Remove a position's principal from bucket + global accounting (no yield change).
    function _removePrincipalFromBucket(
        uint256 apyWad,
        uint256 principal
    ) internal {
        APYBucket storage bucket = apyBuckets[apyWad];
        bucket.totalPrincipal -= principal;
        totalInvestedPrincipal -= principal;
        if (bucket.totalPrincipal == 0) {
            _removeFromActiveAPYs(apyWad);
        }
    }

    /// @dev Add a position's yield contribution to bucket + global aggregates (no principal).
    function _addYieldToBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        apyBuckets[apyWad].weightedYieldStart += principal * yieldStartTime;
        yieldRateSum += apyWad * principal;
        yieldOffsetSum += apyWad * principal * yieldStartTime;
    }

    /// @dev Remove a position's yield contribution from bucket + global aggregates (no principal).
    function _removeYieldFromBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        apyBuckets[apyWad].weightedYieldStart -= principal * yieldStartTime;
        yieldRateSum -= apyWad * principal;
        yieldOffsetSum -= apyWad * principal * yieldStartTime;
    }

    /// @dev Add a fresh position fully (principal + yield). Used by deposit / reinvest.
    function _addToBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        _addPrincipalToBucket(apyWad, principal);
        _addYieldToBucket(apyWad, principal, yieldStartTime);
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
