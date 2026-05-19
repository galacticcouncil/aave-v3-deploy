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

    struct NFTPosition {
        uint256 tokenId;
        uint256 principal;
        uint256 apyWad;
        uint256 depositTime;
        uint256 maturityTime;
        uint256 yieldStartTime;
        NFTState state;
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
    ///         the reinvest check (`totalInvestedPrincipal + amount > tvlCap`)
    ///         intentionally use different reference quantities — both gate new
    ///         principal but neither prevents yield from inflating
    ///         `totalAssets()` once existing positions are productive.
    uint256 public tvlCap;
    /// @notice Whether new deposits are accepted
    bool public depositsPaused;
    /// @notice Minimum HOLLAR for reinvestment
    uint256 public minReinvestAmount;
    /// @notice Minimum HDCL to request redemption
    uint256 public minRedeemAmount;
    /// @notice Chainlink-compatible oracle for wDCL/HOLLAR price
    IAggregatorV3Interface public oracle;

    // ═══════════════════════════════════════════════════════════════════════
    //                          ACCOUNTING STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sum of principal across all yield-bearing positions
    uint256 public totalInvestedPrincipal;
    /// @notice Aggregate: sum(apyWad * principal) across all yield-bearing positions
    uint256 public yieldRateSum;
    /// @notice Aggregate: sum(apyWad * principal * yieldStartTime) across all yield-bearing positions
    uint256 public yieldOffsetSum;
    /// @notice HOLLAR in vault available for queue fulfillment or reinvestment
    uint256 public idleHollar;
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
    event DepositsPaused();
    event DepositsUnpaused();
    event TvlCapUpdated(uint256 newCap);
    event MinReinvestAmountUpdated(uint256 newAmount);
    event MinRedeemAmountUpdated(uint256 newAmount);
    event OracleUpdated(address indexed oracle);

    // ═══════════════════════════════════════════════════════════════════════
    //                            ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error DepositsArePaused();
    error ZeroAmount();
    error ExceedsTvlCap();
    error PositionAlreadyRedeemed();
    error NotRequestOwner();
    error RequestNotActive();
    error InvalidRequestId();
    error BelowMinimumRedeem();

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
    ///         and pending-yield (locked amounts owed by Decentral).
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
    /// @param hollarAmount Amount of HOLLAR to deposit
    /// @return hdclMinted Amount of HDCL minted to caller
    function deposit(
        uint256 hollarAmount
    ) external nonReentrant whenNotPaused returns (uint256 hdclMinted) {
        hdclMinted = _previewMint(hollarAmount);
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
                pendingYield: 0
            })
        );

        _addToBucket(apyWad, amount, block.timestamp);
    }

    /// @notice Queue HDCL for redemption to HOLLAR.
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
            // Wrapped in try/catch like every other Decentral interaction in
            // this function — without it, a paused/shutdown Decentral pool at
            // a position's maturity would revert the whole call and leave the
            // position permanently stuck.
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
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Decentral may be paused/shutdown — no-op so the position
                // stays Active. The next pokeDecentral call retries.
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
                // the locked yield from pending → idle. Discrepancies between
                // pendingYield (the locked estimate) and yieldReceived (what
                // Decentral actually paid) flow through naturally: any shortfall
                // is socialized into the exchange rate, any surplus lifts it.
                totalPendingYield -= pos.pendingYield;
                pos.pendingYield = 0;
                idleHollar += yieldReceived;

                pos.state = NFTState.YieldClaimed;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Not yet approved by Decentral — no-op, retry next cycle
                return;
            }
        }

        // YieldClaimed → PrincipalWithdrawalRequested
        if (pos.state == NFTState.YieldClaimed) {
            try decentralPool.requestPrincipalWithdrawal(pos.tokenId) {
                pos.state = NFTState.PrincipalWithdrawalRequested;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Decentral pool may be paused or broken — no-op, retry next cycle
                return;
            }
        }

        // PrincipalWithdrawalRequested → Redeemed
        if (pos.state == NFTState.PrincipalWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            try decentralPool.executePrincipalWithdrawal(pos.tokenId) {
                uint256 principalReceived = hollar.balanceOf(address(this)) -
                    balBefore;

                // Surface any drift between the principal Decentral paid and
                // what the vault recorded. Mismatches are silently absorbed
                // into idleHollar (positive delta) or come out of the
                // exchange rate (negative delta) — the event lets operators
                // monitor for repeated drift without changing the
                // socialization behavior.
                if (principalReceived != pos.principal) {
                    int256 delta = int256(principalReceived) -
                        int256(pos.principal);
                    emit PrincipalMismatch(
                        positionIndex,
                        pos.tokenId,
                        pos.principal,
                        principalReceived,
                        delta
                    );
                }

                _removePrincipalFromBucket(pos.principal);

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

    /// @dev Validate a deposit and compute the HDCL to mint at the current
    ///      rate. Extracted from `deposit` to keep its stack depth shallow
    ///      enough for via_ir compilation.
    function _previewMint(uint256 hollarAmount)
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
    }

    /// @dev Internal reinvest logic. The cap check here uses the principal
    ///      component only — `totalInvestedPrincipal` — not full
    ///      `totalAssets()`. That's intentional and matches the protocol's
    ///      deposit-cap semantics (see `tvlCap` natspec): reinvest only adds
    ///      NEW principal to Decentral, so it should be limited by the same
    ///      "principal entering the system" rule as deposits, not by inflated
    ///      `totalAssets()` that includes already-accrued yield.
    function _reinvest() internal {
        uint256 amount = idleHollar;

        if (totalInvestedPrincipal >= tvlCap) return;

        // Cap reinvestment so principal doesn't exceed tvlCap. Yield
        // already in idleHollar / accruedYield / pendingYield is unaffected.
        if (totalInvestedPrincipal + amount > tvlCap) {
            amount = tvlCap - totalInvestedPrincipal;
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

            // Expected return: principal + yield.
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
    ///      Advances `queueHead` past cancelled holes (bounded by
    ///      MAX_QUEUE_SKIPS so mass cancellations can't starve real
    ///      redemptions of the iteration budget) and through fulfilled
    ///      entries (bounded by MAX_QUEUE_ITERATIONS for predictable gas).
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

        while (
            queueHead < queueTail &&
            iterations < MAX_QUEUE_ITERATIONS &&
            skips < MAX_QUEUE_SKIPS
        ) {
            RedemptionRequest storage request = redemptionQueue[queueHead];

            if (request.user == address(0)) {
                // Cancelled hole — sweep past without consuming work budget.
                // Bounded by MAX_QUEUE_SKIPS to keep gas predictable under
                // mass cancellations. This sweep happens even with
                // `available == 0` so the queue can be cleaned without funds.
                unchecked { queueHead++; skips++; }
                continue;
            }

            // Hit a real entry. Stop if there's no funds left.
            if (available == 0) break;

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
                        queueHead,
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
                        queueHead,
                        request.user,
                        hollarValue,
                        remainingHdcl
                    );
                }
                delete redemptionQueue[queueHead];
                unchecked { queueHead++; }
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
                        queueHead,
                        request.user,
                        hollarToTransfer,
                        hdclToBurn
                    );

                    hollarUsed += hollarToTransfer;
                    hdclBurned += hdclToBurn;
                    available = 0;
                    // Entry stays at `queueHead` (not deleted). The
                    // available==0 check on the next iteration will break us
                    // out, leaving the partial entry for the next call.
                } else {
                    // Transfer failed mid-partial. Refund the user's full
                    // outstanding HDCL escrow, remove from queue, and continue
                    // — `available` is untouched so the next entry can be tried.
                    uint256 refund = request.hdclAmount - request.hdclFulfilled;
                    _transfer(address(this), request.user, refund);
                    totalQueuedHdcl -= refund;
                    emit RedemptionTransferFailed(
                        queueHead,
                        request.user,
                        hollarToTransfer,
                        refund
                    );
                    delete redemptionQueue[queueHead];
                    unchecked { queueHead++; }
                }
            }
        }
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

    /// @dev Record a fresh position: bump principal counter and add to the
    ///      yield aggregates. Used by deposit and reinvest paths.
    function _addToBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        totalInvestedPrincipal += principal;
        yieldRateSum += apyWad * principal;
        yieldOffsetSum += apyWad * principal * yieldStartTime;
    }

    /// @dev Stop a position from accruing yield without touching its principal.
    ///      Used at Active → YieldWithdrawalRequested when Decentral has locked
    ///      the payout amount.
    function _removeYieldFromBucket(
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        yieldRateSum -= apyWad * principal;
        yieldOffsetSum -= apyWad * principal * yieldStartTime;
    }

    /// @dev Drop a position's principal contribution after Decentral has paid
    ///      it back. Yield aggregates were already cleared at yield-claim time.
    function _removePrincipalFromBucket(uint256 principal) internal {
        totalInvestedPrincipal -= principal;
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
