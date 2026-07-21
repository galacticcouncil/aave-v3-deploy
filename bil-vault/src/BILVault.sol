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
import {IAggregatorV3Interface} from "./interfaces/IAggregatorV3Interface.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IERC7540Operator, IERC7540Redeem} from "./interfaces/IERC7540.sol";
import {QueueLib} from "./libraries/QueueLib.sol";

/// @title BILVault
/// @notice Fungible yield-bearing ERC-20 wrapper around Decentral Protocol NFT positions.
/// @dev Single contract that is the ERC-20 token, vault logic, and Chainlink-compatible oracle.
///      Users deposit HOLLAR → vault deposits into Decentral → vault mints BIL.
///      Exchange rate appreciates over time as yield accrues (non-rebasing model).
contract BILVault is
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

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev Dead shares minted on first deposit to mitigate inflation attack
    uint256 private constant DEAD_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(0xdead);

    uint256 internal constant MAX_QUEUE_ITERATIONS = 50;

    /// @dev Per-call cap on skipping cancelled (zero-address) queue entries.
    ///      Separate from the work cap so a wave of cancels doesn't starve real
    ///      redemptions of their per-call iteration budget. Bounded so a single
    ///      pokeQueue call cannot exceed the block gas limit even if the queue
    ///      contains an unbounded number of holes.
    uint256 internal constant MAX_QUEUE_SKIPS = 500;

    /// @dev Per-call cap on advancing `positionHead` past consecutive Redeemed
    ///      positions. In a multi-pool deployment positions can mature
    ///      out-of-order across pools; if many redeem before their head-side
    ///      neighbors, the eventual head sweep could blow the block gas limit.
    ///      The advancer is idempotent — subsequent calls drain the backlog
    ///      another batch at a time. Also invoked from `pokeQueue` so keeper
    ///      cadence keeps head in sync without requiring a fresh redemption.
    uint256 internal constant MAX_POSITION_HEAD_SWEEP = 50;

    /// @dev Maximum due maturities folded into a queue or lifecycle call.
    ///      Deposits remain disabled until permissionless synchronization has
    ///      drained every overdue root.
    uint256 internal constant MAX_MATURITY_SYNC = 50;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Fast-path role for the Hydration technical committee.
    ///         Authorized to halt and resume deposits and the full vault,
    ///         without going through the slower economics-params governance
    ///         track. Cannot perform any other admin operations.
    ///         Granted post-deploy via `grantRole(GUARDIAN_ROLE, committee)`.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Role authorized to call `redeem`/`withdraw` on behalf of any
    ///         controller that has opted in via `setAutoClaim(true)`. The
    ///         role-holder is constrained to `receiver == controller` — they
    ///         can move the controller's claim timing forward, but cannot
    ///         redirect HOLLAR to a different address. Typically granted to a
    ///         keeper bot that auto-claims for opted-in users right after
    ///         each pokeQueue settlement.
    bytes32 public constant CLAIM_OPERATOR_ROLE = keccak256("CLAIM_OPERATOR_ROLE");

    // ═══════════════════════════════════════════════════════════════════════
    //                          STRUCTS & ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    // RedemptionRequest struct moved to QueueLib.Request — see libraries/QueueLib.sol

    // ═══════════════════════════════════════════════════════════════════════
    //                        IMMUTABLE-LIKE CONFIG
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The pool new deposits and reinvestments route to. Set by
    ///         `setActiveDepositPool` (admin). Existing positions stay anchored
    ///         to whatever pool minted them — see `positionPool`.
    IDecentralPool public activeDepositPool;
    /// @notice All Decentral pools the vault knows about. Includes the active
    ///         one and any older pools still winding down positions.
    IDecentralPool[] public pools;
    /// @notice O(1) registration check.
    mapping(IDecentralPool => bool) public isPoolRegistered;
    /// @notice O(1) check for `onERC721Received` — accepts NFTs from any
    ///         registered pool's NFT contract.
    mapping(address => bool) public isRegisteredPoolToken;
    /// @notice Per-position pool. Kept as a parallel mapping (not a field on
    ///         `NFTPosition`) so future struct extensions don't break the
    ///         storage layout of existing position entries on upgrade.
    mapping(uint256 => IDecentralPool) public positionPool;
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
    /// @notice Minimum BIL to request redemption
    uint256 public minRedeemAmount;
    /// @notice Chainlink-compatible oracle for BIL/HOLLAR price
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
    /// @notice Sum of hollarOwed across all rate-locked redemption requests
    ///         that have not yet been claimed. Backs hDCL still in escrow.
    ///         Must count toward totalAssets() — the HOLLAR sits in the vault
    ///         until users call `redeem`/`withdraw`.
    uint256 public totalReservedHollar;

    // ═══════════════════════════════════════════════════════════════════════
    //                       NFT POSITION TRACKING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice All NFT positions, ordered by deposit time
    QueueLib.NFTPosition[] public positions;
    /// @notice Index of the first non-redeemed position
    uint256 public positionHead;

    // ═══════════════════════════════════════════════════════════════════════
    //                         REDEMPTION QUEUE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice FIFO queue of pending redemptions
    mapping(uint256 => QueueLib.Request) public redemptionQueue;
    /// @notice Index of the first active (unfulfilled) request
    uint256 public queueHead;
    /// @notice Index of the next request to be created
    uint256 public queueTail;
    /// @notice Total BIL across all active queue entries
    uint256 public totalQueuedBil;

    // ═══════════════════════════════════════════════════════════════════════
    //                  ERC-7540 OPERATOR + AUTO-CLAIM
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Per-user operator approval per ERC-7540. The operator may call
    ///         `requestRedeem`, `redeem`, `withdraw` on the controller's
    ///         behalf, and may redirect HOLLAR to any `receiver`.
    mapping(address => mapping(address => bool)) public isOperator;
    /// @notice Per-controller opt-in flag for the `CLAIM_OPERATOR_ROLE` path.
    ///         When true, role-holders may claim on this controller's behalf
    ///         — but `receiver` is forced to equal `controller` (no redirect).
    ///         Users toggle this themselves via `setAutoClaim`; protocol
    ///         contracts that hold hDCL toggle from their own contract logic.
    mapping(address => bool) public autoClaimEnabled;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Deposited(
        address indexed user,
        uint256 hollarAmount,
        uint256 bilMinted,
        uint256 tokenId
    );
    /// @notice ERC-4626 canonical deposit event. Emitted in addition to
    ///         `Deposited` so 4626-aware integrators have the standard shape.
    event Deposit(
        address indexed sender,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    /// @notice ERC-4626 / ERC-7540 canonical withdraw/redeem event.
    ///         Emitted by `redeem` and `withdraw` when a claim is settled.
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    /// @notice ERC-7540 canonical async-redemption request event.
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );
    /// @notice ERC-7540 canonical operator approval event.
    event OperatorSet(
        address indexed controller,
        address indexed operator,
        bool approved
    );
    /// @notice Emitted when a controller toggles their `autoClaimEnabled`
    ///         flag. Users emit this for themselves; protocol contracts emit
    ///         from their own contract logic.
    event AutoClaimSet(address indexed controller, bool enabled);
    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 bilAmount
    );
    event RedemptionCancelled(uint256 indexed requestId, uint256 bilReturned);
    // RedemptionFulfilled / RedemptionPartiallyFulfilled moved to QueueLib.
    // They're emitted under DELEGATECALL so logs still appear at the vault's
    // address and tests' expectEmit matches by topic+data regardless.
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
    /// @notice Emitted when the admin updates the principal/yield mismatch
    ///         circuit-breaker threshold. See `principalMismatchBpsThreshold`.
    event PrincipalMismatchBpsUpdated(uint256 oldBps, uint256 newBps);
    event PoolRegistered(address indexed pool);
    event ActiveDepositPoolSet(address indexed pool);
    event PoolRetired(address indexed pool);
    event PositionYieldCapped(
        uint256 indexed positionIndex,
        uint256 maturityTime,
        uint256 pendingYield
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                            ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error DepositsArePaused();
    error ZeroAmount();
    error ZeroAddress();
    error ExceedsTvlCap();
    error PositionAlreadyRedeemed();
    error NotRequestOwner();
    error RequestNotActive();
    error InvalidRequestId();
    error BelowMinimumRedeem();
    // InsufficientClaimable moved to QueueLib.
    error DepositTooSmall();
    error VaultEmpty();
    error OracleNotSet();
    error OracleInvalidAnswer();
    error OracleRoundIncomplete();
    error OracleStaleRound();
    error OracleDecimalsOutOfRange();
    error NotAdminOrGuardian();
    error NotAuthorized();
    error CapBelowAssets();
    error MinMustBePositive();
    error PoolNotRegistered();
    error CannotRetireActivePool();
    error PoolAlreadyRegistered();
    error PoolWrongStablecoin();
    error PoolNoNFTContract();
    error PoolTokenMismatch();
    error OnlyPoolNFTs();
    error PoolHasOpenPositions();
    /// @notice Reverts pokeDecentral when Decentral pays back materially less
    ///         principal than the vault recorded for the position. Defense in
    ///         depth against H-02: a UUPS-upgraded Decentral impl could add a
    ///         haircut path that atomically shocks the exchange rate (and any
    ///         downstream Aave / stableswap oracle). Operators can pause,
    ///         investigate, then either raise the threshold or pursue recovery
    ///         off-chain before retrying.
    error PrincipalDriftTooLarge(
        uint256 positionIndex,
        uint256 expected,
        uint256 received,
        uint256 shortfallBps
    );
    /// @notice Same shape, for the yield-execute branch. Yield haircuts are
    ///         less severe than principal haircuts but a malicious upgrade
    ///         could compound them, so we gate on the same threshold.
    error YieldDriftTooLarge(
        uint256 positionIndex,
        uint256 expected,
        uint256 received,
        uint256 shortfallBps
    );
    error BpsAboveMax();
    error MaturityBacklog();

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
        if (_decentralPool == address(0)) revert ZeroAddress();
        if (_poolToken == address(0)) revert ZeroAddress();
        if (_hollar == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        __ERC20_init("Brazilian Invoice Loans", "BIL");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        hollar = IERC20(_hollar);
        _registerPool(IDecentralPool(_decentralPool), _poolToken);
        activeDepositPool = IDecentralPool(_decentralPool);
        emit ActiveDepositPoolSet(_decentralPool);
        tvlCap = _tvlCap;
        minReinvestAmount = 10e18; // 10 HOLLAR
        minRedeemAmount = 1e18; // 1 BIL
        // 1% default tolerance for Decentral payout drift (audit H-02). Anything
        // above this trips the circuit breaker in pokeDecentral.
        principalMismatchBpsThreshold = 100;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       CORE ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total value of all vault assets in HOLLAR.
    /// @return Total assets across invested principal, accrued yield, idle
    ///         HOLLAR, pending-yield (locked by Decentral, not yet paid),
    ///         and reserved HOLLAR (rate-locked for redemption claims).
    function totalAssets() public view returns (uint256) {
        uint256 accruedYield = 0;
        if (yieldRateSum > 0) {
            // An overdue heap root clamps the entire live aggregate. Later
            // positions may be conservatively under-counted until sync, but
            // phantom post-maturity yield is impossible even without a keeper.
            uint256 accrualTime = block.timestamp;
            if (_maturityHeap.length > 0) {
                uint256 earliest = _maturityHeap[0] >> 128;
                if (earliest < accrualTime) accrualTime = earliest;
            }
            uint256 gross = accrualTime * yieldRateSum;
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
            totalPendingYield +
            totalReservedHollar;
    }

    /// @notice HOLLAR value of the ACTIVE share pool — total assets minus the
    ///         reserved HOLLAR backing settled (exited) claims.
    /// @dev    Reserved HOLLAR is a fixed liability owed to settled redeemers,
    ///         not value available to active shareholders.
    function _activeAssets() internal view returns (uint256) {
        uint256 total = totalAssets();
        // reserved is always ≤ total (it's a summed component of totalAssets),
        // but clamp defensively.
        return total > totalReservedHollar ? total - totalReservedHollar : 0;
    }

    /// @notice Active (non-settled) share supply. Settled shares are exited —
    ///         they carry a fixed claim and must not share in active yield.
    ///         Dead shares are active, so this stays ≥ DEAD_SHARES once
    ///         bootstrapped (the rate denominator can't hit zero).
    function _activeSupply() internal view returns (uint256) {
        uint256 supply = totalSupply();
        return supply > totalSettledBil ? supply - totalSettledBil : 0;
    }

    /// @notice Current BIL/HOLLAR exchange rate (18 decimals) — the value of
    ///         one ACTIVE share.
    /// @dev    Prices active shares against active assets only; settled shares
    ///         and their reserved HOLLAR are excluded (Pashov High —
    ///         settled-share dilution). Because a share is settled at exactly
    ///         this rate (hollarOwed = shares × rate), settlement is
    ///         rate-neutral: removing (shares, shares×rate) from the active
    ///         pool leaves the ratio unchanged.
    /// @return Rate in WAD (1e18 = 1:1)
    function exchangeRate() public view returns (uint256) {
        uint256 activeSupply = _activeSupply();
        if (activeSupply == 0) return WAD;
        return (_activeAssets() * WAD) / activeSupply;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice ERC-4626 deposit. Pulls `assets` HOLLAR from msg.sender and
    ///         mints the corresponding hDCL shares to `receiver`.
    /// @param assets   Amount of HOLLAR to deposit
    /// @param receiver Address that receives the minted hDCL
    /// @return shares  Amount of hDCL minted to `receiver`
    function deposit(
        uint256 assets,
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        shares = _validateAndPreviewShares(assets);
        _requireNoMaturityBacklog();
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice ERC-4626 mint. Mints exactly `shares` hDCL to `receiver` and
    ///         pulls the necessary HOLLAR from msg.sender.
    /// @param shares    Amount of hDCL to mint
    /// @param receiver  Address that receives the minted hDCL
    /// @return assets   HOLLAR consumed
    function mint(
        uint256 shares,
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        _requireNoMaturityBacklog();
        assets = previewMint(shares);
        // Reuse the same validation path: paused/zero/cap checks
        // run again on the computed asset amount.
        _validateDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Shared deposit body: mint hDCL, pull HOLLAR, push into Decentral.
    function _deposit(
        address sender,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        if (totalSupply() == 0) _mint(DEAD_ADDRESS, DEAD_SHARES);
        _mint(receiver, shares);
        hollar.safeTransferFrom(sender, address(this), assets);
        uint256 tokenId = _depositIntoDecentral(assets);
        emit Deposited(receiver, assets, shares, tokenId);
        emit Deposit(sender, receiver, assets, shares);
    }

    /// @dev Forward HOLLAR to Decentral and record the new NFT position.
    ///      Extracted from `deposit` and `_reinvest` to keep their stack depths
    ///      shallow enough for via_ir compilation.
    function _depositIntoDecentral(uint256 amount) internal returns (uint256 tokenId) {
        IDecentralPool pool = activeDepositPool;
        uint256 apyWad = pool.fixedAPYWad();
        hollar.safeApprove(address(pool), 0);
        hollar.safeApprove(address(pool), amount);
        tokenId = pool.deposit(amount);

        uint256 idx = positions.length;
        positions.push(
            QueueLib.NFTPosition({
                tokenId: tokenId,
                principal: amount,
                apyWad: apyWad,
                depositTime: block.timestamp,
                maturityTime: block.timestamp + _investmentPeriod(pool),
                yieldStartTime: block.timestamp,
                state: QueueLib.NFTState.Active,
                yieldCapped: false,
                pendingYield: 0
            })
        );
        positionPool[idx] = pool;

        _addToBucket(idx, apyWad, amount, block.timestamp);
    }

    /// @notice ERC-7540 async-redemption request. Escrows `shares` hDCL
    ///         from `owner` and creates a queue entry the `controller`
    ///         will manage and claim.
    /// @dev    msg.sender must be `owner` or an approved operator of `owner`.
    /// @param shares      Amount of hDCL to escrow
    /// @param controller  Address authorized to claim the resulting HOLLAR
    /// @param owner       Address whose hDCL is escrowed
    /// @return requestId  ID of the redemption request
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (shares < minRedeemAmount) revert BelowMinimumRedeem();
        if (controller == address(0)) revert ZeroAddress();
        if (owner == address(0)) revert ZeroAddress();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert NotAuthorized();

        // Escrow BIL from owner. The vault's per-user operator approval
        // covers this — no per-token allowance needed.
        _transfer(owner, address(this), shares);

        requestId = queueTail;
        redemptionQueue[requestId] = QueueLib.Request({
            user: controller,
            bilAmount: shares,
            bilSettled: 0,
            hollarOwed: 0
        });
        queueTail++;
        totalQueuedBil += shares;

        emit RedemptionRequested(requestId, controller, shares);
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  OPERATOR + AUTO-CLAIM (ERC-7540)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Per-user operator approval. Approved operators may call
    ///         `requestRedeem`, `redeem`, `withdraw` on the controller's
    ///         behalf, including redirecting HOLLAR to any receiver.
    /// @param  operator  Address being approved or revoked
    /// @param  approved  Approval state
    function setOperator(address operator, bool approved) external {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    /// @notice Toggle the role-based auto-claim flag for msg.sender.
    /// @dev    When `enabled` is true, addresses holding `CLAIM_OPERATOR_ROLE`
    ///         may call `redeem`/`withdraw` on msg.sender's behalf — but
    ///         `receiver` is forced to equal msg.sender (no redirect).
    ///         Users opt in for themselves; protocol contracts opt in from
    ///         their own contract logic.
    function setAutoClaim(bool enabled) external {
        autoClaimEnabled[msg.sender] = enabled;
        emit AutoClaimSet(msg.sender, enabled);
    }

    /// @notice Cancel the still-unsettled portion of a redemption request.
    /// @dev    Refunds the unsettled hDCL back to the user. Any already-settled
    ///         portion (bilSettled > 0) stays alive as a claim — the user
    ///         must call `redeem` / `withdraw` to receive the HOLLAR. If the
    ///         request was fully unsettled at cancel time, it's deleted from
    ///         the queue entirely.
    function cancelRedeem(uint256 requestId) external nonReentrant {
        if (requestId >= queueTail) revert InvalidRequestId();
        QueueLib.Request storage request = redemptionQueue[requestId];
        address controller = request.user;
        if (controller == address(0)) revert RequestNotActive();
        if (msg.sender != controller && !isOperator[controller][msg.sender])
            revert NotRequestOwner();

        uint256 unsettled = request.bilAmount - request.bilSettled;
        if (unsettled > 0) {
            totalQueuedBil -= unsettled;
            request.bilAmount = request.bilSettled; // shrink to settled portion
            // Refund the unsettled hDCL to the controller. When an operator
            // cancels, the funds still go to the controller, not the operator.
            _transfer(address(this), controller, unsettled);
            emit RedemptionCancelled(requestId, unsettled);
        }

        // If nothing was settled, the request has nothing left — delete it
        // and try to compact the queue head.
        if (request.bilSettled == 0) {
            delete redemptionQueue[requestId];

            // Head sweep — same logic as before, bounded by MAX_QUEUE_ITERATIONS
            // so the canceller's gas stays bounded even with many head holes.
            if (requestId == queueHead) {
                queueHead = QueueLib.advanceQueueHead(
                    redemptionQueue,
                    queueHead,
                    queueTail,
                    MAX_QUEUE_ITERATIONS
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       CLAIM (pull settlement)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim hDCL → HOLLAR for previously-settled redemption requests.
    /// @dev    Walks the controller's settled requests in FIFO order, drawing
    ///         down `bilSettled` and `hollarOwed` pro-rata until the
    ///         requested `shares` is exhausted. Burns the escrowed hDCL and
    ///         transfers HOLLAR to `receiver`.
    ///
    ///         Three authorization paths:
    ///         1. `msg.sender == controller` — self-claim
    ///         2. `isOperator[controller][msg.sender]` — per-user operator
    ///            approved via `setOperator` (can redirect to any receiver)
    ///         3. `CLAIM_OPERATOR_ROLE` holder AND `autoClaimEnabled[controller]`
    ///            AND `receiver == controller` — role-based auto-claim,
    ///            restricted to paying the controller's own address
    /// @param shares      Amount of hDCL to claim
    /// @param receiver    Address that receives HOLLAR
    /// @param controller  Address whose claimable inventory is drawn down
    /// @return assets     HOLLAR transferred to receiver
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _authorizeClaim(receiver, controller);

        assets = QueueLib.claimByShares(redemptionQueue, _settledByController, controller, shares);

        _burn(address(this), shares);
        totalQueuedBil -= shares;
        totalSettledBil -= shares; // settled shares leaving supply on claim
        totalReservedHollar -= assets;
        hollar.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @notice Claim by HOLLAR amount instead of share count.
    /// @dev    Same auth model as `redeem` — see those docs.
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _authorizeClaim(receiver, controller);

        (shares, assets) = QueueLib.claimByAssets(redemptionQueue, _settledByController, controller, assets);

        _burn(address(this), shares);
        totalQueuedBil -= shares;
        totalSettledBil -= shares; // settled shares leaving supply on claim
        totalReservedHollar -= assets;
        hollar.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @dev Verify the caller is authorized to claim on the controller's
    ///      behalf. See `redeem` natspec for the three accepted paths.
    function _authorizeClaim(address receiver, address controller) internal view {
        if (msg.sender == controller) return;
        if (isOperator[controller][msg.sender]) return;
        // Role path: must be a CLAIM_OPERATOR_ROLE holder, controller must
        // have opted in, and receiver must be the controller itself (no
        // redirect — the role grants timing, not destination).
        if (
            !hasRole(CLAIM_OPERATOR_ROLE, msg.sender)
                || !autoClaimEnabled[controller]
                || receiver != controller
        ) revert NotAuthorized();
    }

    // _claimByShares / _claimByAssets inlined as direct QueueLib calls in
    // redeem() / withdraw() above — see libraries/QueueLib.sol for semantics.

    // ═══════════════════════════════════════════════════════════════════════
    //                    PERMISSIONLESS OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Advance a position through its Decentral withdrawal lifecycle
    /// @dev Callable by anyone (bot or user). Claims mature NFT yield/principal from Decentral.
    /// @param positionIndex Index in the positions array
    function pokeDecentral(
        uint256 positionIndex
    ) external nonReentrant whenNotPaused {
        QueueLib.NFTPosition storage pos = positions[positionIndex];
        if (pos.state == QueueLib.NFTState.Redeemed) revert PositionAlreadyRedeemed();

        _syncMaturities(MAX_MATURITY_SYNC);

        IDecentralPool pool = positionPool[positionIndex];

        // Active → YieldWithdrawalRequested
        if (
            pos.state == QueueLib.NFTState.Active && block.timestamp >= pos.maturityTime
        ) {
            // The chronological heap sync above must have capped this position
            // before its Decentral lifecycle can advance. A larger overdue
            // backlog is drained over subsequent permissionless calls.
            if (!pos.yieldCapped) return;

            // A zero-APY or dust-rounded position has no yield withdrawal to
            // request. Skip directly to the principal path; using pendingYield
            // itself as the cap marker would leave this position stuck Active.
            if (pos.pendingYield == 0) {
                pos.state = QueueLib.NFTState.YieldClaimed;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } else {
                // Wrapped in try/catch like every other Decentral interaction
                // so a paused/shutdown pool can be retried later.
                try pool.requestYieldWithdrawal(pos.tokenId) {
                    pos.state = QueueLib.NFTState.YieldWithdrawalRequested;
                    emit PositionProcessed(
                        positionIndex,
                        pos.tokenId,
                        uint8(pos.state)
                    );
                } catch {
                    // The cap remains locked in while the request is retried.
                    return;
                }
            }
        }

        // YieldWithdrawalRequested → YieldClaimed
        if (pos.state == QueueLib.NFTState.YieldWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            uint256 expectedYield = pos.pendingYield;
            uint256 yieldReceived;
            try pool.executeYieldWithdrawal(pos.tokenId) {
                yieldReceived = hollar.balanceOf(address(this)) - balBefore;

                // Bucket bookkeeping was already cleared at request time. Move
                // the locked yield from pending → idle. Discrepancies between
                // pendingYield (the locked estimate) and yieldReceived (what
                // Decentral actually paid) flow through naturally: any shortfall
                // is socialized into the exchange rate, any surplus lifts it.
                totalPendingYield -= pos.pendingYield;
                pos.pendingYield = 0;
                idleHollar += yieldReceived;

                pos.state = QueueLib.NFTState.YieldClaimed;
                emit PositionProcessed(
                    positionIndex,
                    pos.tokenId,
                    uint8(pos.state)
                );
            } catch {
                // Not yet approved by Decentral — no-op, retry next cycle
                return;
            }

            // H-02 circuit breaker: outside the try/catch so the revert
            // propagates up. Only a shortfall trips it; surplus is benign and
            // lifts the rate. Skipped when expectedYield is zero (no pending
            // yield to compare against, e.g., dust-rounded positions).
            if (expectedYield > 0 && yieldReceived < expectedYield) {
                uint256 shortfallBps = ((expectedYield - yieldReceived) *
                    10_000) / expectedYield;
                if (shortfallBps > principalMismatchBpsThreshold) {
                    revert YieldDriftTooLarge(
                        positionIndex,
                        expectedYield,
                        yieldReceived,
                        shortfallBps
                    );
                }
            }
        }

        // YieldClaimed → PrincipalWithdrawalRequested
        if (pos.state == QueueLib.NFTState.YieldClaimed) {
            try pool.requestPrincipalWithdrawal(pos.tokenId) {
                pos.state = QueueLib.NFTState.PrincipalWithdrawalRequested;
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
        if (pos.state == QueueLib.NFTState.PrincipalWithdrawalRequested) {
            uint256 balBefore = hollar.balanceOf(address(this));
            uint256 expectedPrincipal = pos.principal;
            uint256 principalReceived;
            try pool.executePrincipalWithdrawal(pos.tokenId) {
                principalReceived = hollar.balanceOf(address(this)) - balBefore;

                // Surface any drift between the principal Decentral paid and
                // what the vault recorded. Sub-threshold mismatches are
                // silently absorbed into idleHollar (positive delta) or come
                // out of the exchange rate (negative delta) — the event lets
                // operators monitor for repeated drift without changing the
                // socialization behavior. Catastrophic shortfalls trip the
                // circuit breaker below (audit H-02).
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

                _removePrincipalFromBucket(expectedPrincipal);

                idleHollar += principalReceived;
                pos.state = QueueLib.NFTState.Redeemed;
                _advancePositionHead();

                emit PositionRedeemed(
                    positionIndex,
                    pos.tokenId,
                    0,
                    principalReceived
                );

                // Distribute available HOLLAR to queue
                if (
                    totalQueuedBil > 0 &&
                    idleHollar > 0 &&
                    !_hasMaturedBacklog()
                ) {
                    uint256 rate = exchangeRate();
                    _processQueueWithHollar(idleHollar, rate);
                }
            } catch {
                // Not yet approved or delay not elapsed — no-op
                return;
            }

            // H-02 circuit breaker: outside the try/catch so the revert
            // propagates up. Only a shortfall trips it; surplus is benign and
            // lifts the rate. The whole transaction reverts (including the
            // state and bucket changes above), so the vault refuses to absorb
            // a catastrophic shock atomically. Operations can pause and
            // investigate before retrying.
            if (principalReceived < expectedPrincipal) {
                uint256 shortfallBps = ((expectedPrincipal -
                    principalReceived) * 10_000) / expectedPrincipal;
                if (shortfallBps > principalMismatchBpsThreshold) {
                    revert PrincipalDriftTooLarge(
                        positionIndex,
                        expectedPrincipal,
                        principalReceived,
                        shortfallBps
                    );
                }
            }
        }
    }

    /// @notice Permissionlessly cap up to `maxPositions` due maturities in
    ///         chronological order. Safe to call while the vault is paused.
    /// @dev Deposits and mints remain disabled while any due root remains.
    function syncMaturities(
        uint256 maxPositions
    ) external returns (uint256 processed) {
        processed = _syncMaturities(maxPositions);
    }

    /// @notice Process queued redemptions, then reinvest remaining idle HOLLAR
    /// @dev Callable by anyone (bot or user). Processes first MAX_QUEUE_ITERATIONS withdrawals,
    ///      then reinvests remaining idle HOLLAR if the queue couldn't progress.
    function pokeQueue() external nonReentrant whenNotPaused {
        _syncBeforeRateSensitiveAction();
        uint256 rate = exchangeRate();

        // Always invoke the queue processor. With funds, it processes redemptions;
        // without funds, it still sweeps cancelled entries off the head, keeping
        // the queue compact in adversarial cancel-spam scenarios.
        (uint256 hollarUsed, ) = _processQueueWithHollar(idleHollar, rate);

        // Drain a batch of stacked Redeemed positions off the head if any.
        // Cheap when there's nothing to do (loop exits on first non-Redeemed).
        // In multi-pool deployments positions mature out-of-order; without this
        // call the cleanup only happens on the next pokeDecentral redemption.
        _advancePositionHead();

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

    /// @dev Validate the size/state preconditions for a deposit. Used by both
    ///      `deposit` (after computing shares) and `mint` (after computing
    ///      the assets required for a target share count).
    function _validateDeposit(uint256 assets) internal view {
        if (depositsPaused) revert DepositsArePaused();
        if (assets == 0) revert ZeroAmount();
        if (totalAssets() + assets > tvlCap) revert ExceedsTvlCap();
    }

    /// @dev Validate and compute share count for an asset deposit.
    ///      Extracted to keep `deposit`'s stack depth shallow enough for
    ///      via_ir compilation.
    function _validateAndPreviewShares(uint256 assets)
        internal
        view
        returns (uint256 shares)
    {
        _validateDeposit(assets);

        uint256 supply = totalSupply();
        if (supply == 0) {
            if (assets <= DEAD_SHARES) revert DepositTooSmall();
            shares = assets - DEAD_SHARES;
        } else {
            // Mint against the ACTIVE pool — settled shares and their
            // reserved HOLLAR are excluded so a new depositor pays the true
            // active rate, not a rate diluted by lingering settled claims.
            uint256 activeSupply = _activeSupply();
            uint256 activeA = _activeAssets();
            // Catastrophic state: active shares exist but no active backing.
            // Refuse to deposit at a zero rate — the depositor would receive
            // no BIL and lose their HOLLAR.
            if (activeA == 0 || activeSupply == 0) revert VaultEmpty();
            shares = (assets * activeSupply) / activeA;
            if (shares == 0) revert DepositTooSmall();
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

        uint256 tokenId = _depositIntoDecentral(amount);
        idleHollar -= amount;

        emit Reinvested(amount, tokenId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       ERC-4626 VIEW SURFACE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The underlying asset (HOLLAR).
    function asset() external view returns (address) {
        return address(hollar);
    }

    /// @notice Convert HOLLAR → hDCL at the current rate (no fees, no
    ///         first-deposit dust). For empty supply, returns 1:1.
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 activeSupply = _activeSupply();
        if (activeSupply == 0) return assets; // fresh/empty active pool → 1:1
        uint256 activeA = _activeAssets();
        if (activeA == 0) return 0;
        return (assets * activeSupply) / activeA;
    }

    /// @notice Convert hDCL → HOLLAR at the current (active) rate.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 activeSupply = _activeSupply();
        if (activeSupply == 0) return shares;
        return (shares * _activeAssets()) / activeSupply;
    }

    /// @notice Max HOLLAR `receiver` can deposit right now.
    /// @dev    Returns 0 if deposits are paused, a maturity checkpoint is due,
    ///         or the TVL cap is already reached. Otherwise returns the
    ///         remaining headroom under the cap.
    function maxDeposit(address /* receiver */) public view returns (uint256) {
        if (paused() || depositsPaused || _hasMaturedBacklog()) return 0;
        uint256 totalA = totalAssets();
        if (totalA >= tvlCap) return 0;
        return tvlCap - totalA;
    }

    /// @notice Max hDCL `receiver` can mint right now.
    function maxMint(address receiver) external view returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice ERC-7540 `maxWithdraw`: total HOLLAR currently claimable by
    ///         `controller` across all of their settled requests.
    /// @dev    Walks the per-controller settled-index — bounded by the user's
    ///         own outstanding settled-but-unclaimed requests (immune to
    ///         cancel-spam DoS). Per ERC-7540 §maxRedeem/maxWithdraw, returns
    ///         the value of all settled-but-unclaimed requests for the caller.
    function maxWithdraw(address controller) external view returns (uint256 max) {
        return QueueLib.sumSettled(
            redemptionQueue,
            _settledByController[controller],
            controller,
            true
        );
    }

    /// @notice ERC-7540 `maxRedeem`: total hDCL currently claimable by
    ///         `controller` across all of their settled requests. Same
    ///         iteration bound as `maxWithdraw`.
    function maxRedeem(address controller) external view returns (uint256 max) {
        return QueueLib.sumSettled(
            redemptionQueue,
            _settledByController[controller],
            controller,
            false
        );
    }

    /// @notice Preview how much HOLLAR is needed to mint exactly `shares` hDCL.
    /// @dev    Rounds up to favor the vault — mint will pull at least this much.
    function previewMint(uint256 shares) public view returns (uint256 assets) {
        uint256 activeSupply = _activeSupply();
        if (activeSupply == 0) {
            // First-deposit dust: caller must overpay DEAD_SHARES wei to
            // mint `shares` to themselves while DEAD_SHARES go to 0xdead.
            return shares + DEAD_SHARES;
        }
        uint256 activeA = _activeAssets();
        // ceil(shares * activeA / activeSupply)
        return (shares * activeA + activeSupply - 1) / activeSupply;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       VAULT-SPECIFIC VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Preview how much BIL a HOLLAR deposit would mint.
    /// @dev    Returns 0 for inputs that would revert in `deposit` (zero amount,
    ///         first-deposit dust below DEAD_SHARES). Lets off-chain callers
    ///         distinguish "would succeed with N BIL" from "would revert"
    ///         without forcing them to catch a Solidity revert.
    /// @notice ERC-4626 `previewDeposit`. Returns the hDCL that `deposit`
    ///         would mint for `hollarAmount` HOLLAR at the current rate.
    /// @dev    Per ERC-4626, preview MUST reflect what the actual `deposit`
    ///         call would do "in the same transaction" — so this reverts on
    ///         every math edge that `deposit` reverts on. It does NOT honor
    ///         `depositsPaused` or `tvlCap` (the spec excludes "user/global
    ///         limits" from preview), so callers can still preview-size an
    ///         eventual unpaused deposit.
    function previewDeposit(
        uint256 hollarAmount
    ) external view returns (uint256 bilAmount) {
        if (hollarAmount == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (hollarAmount <= DEAD_SHARES) revert DepositTooSmall();
            return hollarAmount - DEAD_SHARES;
        }
        uint256 activeSupply = _activeSupply();
        uint256 activeA = _activeAssets();
        // Catastrophic state: active shares exist but no active backing.
        // `deposit` would revert with VaultEmpty before the divide; mirror it.
        if (activeA == 0 || activeSupply == 0) revert VaultEmpty();
        bilAmount = (hollarAmount * activeSupply) / activeA;
        if (bilAmount == 0) revert DepositTooSmall();
    }

    /// @notice Preview the HOLLAR value of a BIL redemption at the current
    ///         (active) rate.
    function previewRedeem(
        uint256 bilAmount
    ) external view returns (uint256 hollarAmount) {
        uint256 activeSupply = _activeSupply();
        if (activeSupply == 0) return 0;
        return (bilAmount * _activeAssets()) / activeSupply;
    }

    /// @notice ERC-4626 sync withdraw preview — async-only vault returns 0.
    function previewWithdraw(uint256 /* assets */) external pure returns (uint256) {
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       ERC-7540 PER-REQUEST VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Shares of `requestId` that are still waiting to be processed
    ///         (i.e., queued but not yet rate-locked).
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares)
    {
        QueueLib.Request storage r = redemptionQueue[requestId];
        if (r.user != controller) return 0;
        return r.bilAmount - r.bilSettled;
    }

    /// @notice Shares of `requestId` that have been rate-locked and are
    ///         ready to claim via `redeem` / `withdraw`.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares)
    {
        QueueLib.Request storage r = redemptionQueue[requestId];
        if (r.user != controller) return 0;
        return r.bilSettled;
    }

    /// @notice Get estimated wait time for a redemption request
    /// @return estimatedSeconds Seconds until expected full fulfillment
    function getEstimatedWaitTime(
        uint256 requestId
    ) external view returns (uint256 estimatedSeconds) {
        return QueueLib.estimatedWaitTime(
            redemptionQueue,
            positions,
            positionPool,
            requestId,
            queueHead,
            positionHead,
            exchangeRate(),
            WAD,
            idleHollar,
            SECONDS_PER_YEAR * WAD,
            block.timestamp
        );
    }

    /// @notice Get redemption request details
    function getRedemptionRequest(
        uint256 requestId
    )
        external
        view
        returns (
            address user,
            uint256 bilAmount,
            uint256 bilSettled,
            uint256 hollarOwed,
            bool active
        )
    {
        QueueLib.Request storage r = redemptionQueue[requestId];
        return (r.user, r.bilAmount, r.bilSettled, r.hollarOwed, r.user != address(0));
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
        QueueLib.NFTPosition storage pos = positions[positionIndex];
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

    /// @notice Total BIL currently queued for redemption
    function getTotalQueuedBil() external view returns (uint256) {
        return totalQueuedBil;
    }

    /// @notice HOLLAR available for queue fulfillment or reinvestment
    function getIdleHollar() external view returns (uint256) {
        return idleHollar;
    }

    /// @notice Current fixed APY from the Decentral pool
    function getAPYWad() public view returns (uint256) {
        return activeDepositPool.fixedAPYWad();
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

    /// @notice Get BIL/HOLLAR price from the oracle, returned in 18 decimals.
    /// @dev    Defensive Chainlink-style checks. `BILOracle` is always-fresh
    ///         by construction, so these are mostly inert today, but
    ///         `setOracle` allows rotation to a heartbeat-style feed (e.g.,
    ///         Chainlink) where staleness becomes critical. Each check below
    ///         catches a documented Chainlink failure mode:
    ///           - `roundId != 0` — feed has been initialized
    ///           - `updatedAt > 0` — round actually completed
    ///           - `answeredInRound >= roundId` — answer isn't carry-over
    ///             from a prior round (stale data).
    function getOraclePrice() external view returns (uint256) {
        return QueueLib.oraclePrice(oracle);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Restricts a function to addresses holding either ADMIN_ROLE or
    ///      GUARDIAN_ROLE. Admin retains a strict superset of guardian's
    ///      authority — anything the guardian can do, the admin can do too.
    modifier onlyAdminOrGuardian() {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotAdminOrGuardian();
        }
        _;
    }

    /// @notice Stop new deposits. Callable by ADMIN_ROLE or GUARDIAN_ROLE.
    function pauseDeposits() external onlyAdminOrGuardian {
        depositsPaused = true;
        emit DepositsPaused();
    }

    /// @notice Resume deposits. Callable by ADMIN_ROLE or GUARDIAN_ROLE.
    function unpauseDeposits() external onlyAdminOrGuardian {
        depositsPaused = false;
        emit DepositsUnpaused();
    }

    /// @notice Emergency pause — stops all state-changing operations.
    ///         Callable by ADMIN_ROLE or GUARDIAN_ROLE.
    function pause() external onlyAdminOrGuardian {
        _pause();
    }

    /// @notice Resume all operations. Callable by ADMIN_ROLE or GUARDIAN_ROLE.
    function unpause() external onlyAdminOrGuardian {
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
        if (newCap < totalAssets()) revert CapBelowAssets();
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
    ///         zero-BIL redemption requests that pass `requestRedeem`'s
    ///         `bilAmount < minRedeemAmount` check, escrow zero BIL,
    ///         and still consume one iteration of `_processQueueWithHollar`'s
    ///         work budget per spam entry — a cheap queue grief.
    function setMinRedeemAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert MinMustBePositive();
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
        if (_oracle == address(0)) revert ZeroAddress();

        IAggregatorV3Interface candidate = IAggregatorV3Interface(_oracle);
        QueueLib.validateOracle(candidate);

        oracle = candidate;
        emit OracleUpdated(_oracle);
    }

    /// @notice Update the circuit-breaker threshold for Decentral payout drift.
    /// @dev    Defense in depth against H-02. A shortfall (bps of the recorded
    ///         expected amount) above this threshold reverts `pokeDecentral`
    ///         in both the yield- and principal-execute branches, refusing to
    ///         atomically socialize a catastrophic shock into `exchangeRate()`.
    ///         Surplus is always tolerated (lifts the rate). Set to `10000`
    ///         (100%) to effectively disable; set to `0` to be maximally strict
    ///         (any sub-expected payout reverts).
    /// @param  bps  New threshold in basis points. Must be <= 10_000.
    function setPrincipalMismatchBpsThreshold(uint256 bps)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (bps > 10_000) revert BpsAboveMax();
        uint256 old = principalMismatchBpsThreshold;
        principalMismatchBpsThreshold = bps;
        emit PrincipalMismatchBpsUpdated(old, bps);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       POOL REGISTRY (ADMIN)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Register a new Decentral pool the vault can interact with.
    /// @dev    Validates the pool uses the same HOLLAR stablecoin. Adds the
    ///         pool's NFT contract to the receiver allow-list. If this is the
    ///         first pool registered, it also becomes the active deposit pool.
    function registerPool(IDecentralPool newPool) external onlyRole(ADMIN_ROLE) {
        _registerPool(newPool, address(0));
    }

    /// @notice Switch which registered pool receives new deposits and
    ///         reinvestments. Existing positions stay anchored to whichever
    ///         pool minted them.
    function setActiveDepositPool(IDecentralPool pool) external onlyRole(ADMIN_ROLE) {
        if (!isPoolRegistered[pool]) revert PoolNotRegistered();
        activeDepositPool = pool;
        emit ActiveDepositPoolSet(address(pool));
    }

    /// @notice Remove a pool from the registry.
    /// @dev    Reverts if `pool` is the active deposit pool (switch first), or
    ///         if any open (non-Redeemed) position still belongs to it. Forces
    ///         the operator to drain a pool before forgetting about it; keeps
    ///         the invariant that every registered pool is reachable.
    function retirePool(IDecentralPool pool) external onlyRole(ADMIN_ROLE) {
        if (!isPoolRegistered[pool]) revert PoolNotRegistered();
        if (pool == activeDepositPool) revert CannotRetireActivePool();

        QueueLib.removePool(
            positions,
            positionPool,
            pools,
            positionHead,
            pool
        );

        isPoolRegistered[pool] = false;
        isRegisteredPoolToken[address(pool.poolToken())] = false;

        emit PoolRetired(address(pool));
    }

    /// @notice Number of registered pools (active + retiring).
    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @dev Shared registration logic used by both `initialize` and
    ///      `registerPool`. The optional `expectedPoolToken` arg lets
    ///      `initialize` assert ABI-compatibility with its legacy `_poolToken`
    ///      param (which would otherwise be unused). Pass `address(0)` to
    ///      skip the assertion.
    function _registerPool(IDecentralPool newPool, address expectedPoolToken) internal {
        QueueLib.registerPool(
            isPoolRegistered,
            isRegisteredPoolToken,
            pools,
            newPool,
            address(hollar),
            expectedPoolToken
        );

        emit PoolRegistered(address(newPool));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         ERC-721 RECEIVER
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accept NFTs from any registered Decentral pool's mint.
    /// @dev    Only NFT contracts belonging to a registered pool may push NFTs
    ///         to the vault. Without this guard, anyone can transfer arbitrary
    ///         NFTs into the vault — no fund-impact path (position iteration
    ///         uses `positions[]`, not the held-NFT set) but storage and event
    ///         spam are real and cheap to prevent.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
        if (!isRegisteredPoolToken[msg.sender]) revert OnlyPoolNFTs();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Process queue entries by **rate-locking** them, not by transferring
    ///      HOLLAR. Each settled portion moves HOLLAR from `idleHollar` into
    ///      `totalReservedHollar` and records the locked amount on the
    ///      request's `hollarOwed`. Users (or operators) call `redeem` /
    ///      `withdraw` later to actually receive HOLLAR.
    ///
    ///      Uses two pointers:
    ///       - `queueHead`: lowest index claim walkers should start scanning.
    ///         Advances only past cancelled holes — settled-but-unclaimed
    ///         entries stay in `[queueHead, queueTail)` so claim can find them.
    ///       - `cursor`: this call's scan position; may run ahead of queueHead.
    ///      Bounded by MAX_QUEUE_SKIPS (skip budget for holes + already-settled
    ///      entries) and MAX_QUEUE_ITERATIONS (real settlement work).
    ///
    /// @param available HOLLAR available to rate-lock
    /// @param rate Current exchange rate (WAD)
    /// @return hollarUsed Total HOLLAR moved from idle into reserved
    /// @return bilLocked Total hDCL rate-locked across requests this call
    function _processQueueWithHollar(
        uint256 available,
        uint256 rate
    ) internal returns (uint256 hollarUsed, uint256 bilLocked) {
        uint256 newHead;
        (newHead, hollarUsed, bilLocked) = QueueLib.processQueue(
            redemptionQueue,
            _settledByController,
            queueHead,
            queueTail,
            available,
            rate,
            MAX_QUEUE_ITERATIONS,
            MAX_QUEUE_SKIPS,
            WAD
        );
        queueHead = newHead;
        // Library returns net deltas; apply to vault globals here so the
        // storage-write surface stays explicit at the call boundary.
        idleHollar -= hollarUsed;
        totalReservedHollar += hollarUsed;
        // Shares just rate-locked join the settled (exited) pool — excluded
        // from the active exchange rate from here until claim burns them.
        totalSettledBil += bilLocked;
    }

    /// @dev Advance positionHead past redeemed positions
    function _advancePositionHead() internal {
        positionHead = QueueLib.advancePositionHead(
            positions,
            positionHead,
            MAX_POSITION_HEAD_SWEEP
        );
    }

    /// @dev Record a fresh position: bump principal counter and add to the
    ///      yield aggregates. Used by deposit and reinvest paths.
    function _addToBucket(
        uint256 positionIndex,
        uint256 apyWad,
        uint256 principal,
        uint256 yieldStartTime
    ) internal {
        totalInvestedPrincipal += principal;
        yieldRateSum += apyWad * principal;
        yieldOffsetSum += apyWad * principal * yieldStartTime;
        QueueLib.pushMaturity(
            _maturityHeap,
            positions[positionIndex].maturityTime,
            positionIndex
        );
    }

    function _syncMaturities(
        uint256 maxPositions
    ) internal returns (uint256 processed) {
        uint256 newRateSum;
        uint256 newOffsetSum;
        uint256 pendingAdded;
        (processed, newRateSum, newOffsetSum, pendingAdded) =
            QueueLib.processMaturities(
                positions,
                _maturityHeap,
                maxPositions,
                block.timestamp,
                yieldRateSum,
                yieldOffsetSum,
                SECONDS_PER_YEAR * WAD
            );
        yieldRateSum = newRateSum;
        yieldOffsetSum = newOffsetSum;
        totalPendingYield += pendingAdded;
    }

    function _syncBeforeRateSensitiveAction() internal {
        _syncMaturities(MAX_MATURITY_SYNC);
        _requireNoMaturityBacklog();
    }

    function _requireNoMaturityBacklog() internal view {
        if (_hasMaturedBacklog()) revert MaturityBacklog();
    }

    function _hasMaturedBacklog() internal view returns (bool) {
        return
            _maturityHeap.length > 0 &&
            (_maturityHeap[0] >> 128) <= block.timestamp;
    }

    /// @dev Drop a position's principal contribution after Decentral has paid
    ///      it back. Yield aggregates were already cleared at yield-claim time.
    function _removePrincipalFromBucket(uint256 principal) internal {
        totalInvestedPrincipal -= principal;
    }

    /// @dev Returns the minimum investment period from a specific Decentral pool
    function _investmentPeriod(IDecentralPool pool) internal view returns (uint256) {
        return pool.minimumInvestmentPeriodSeconds();
    }

    /// @dev Authorize UUPS upgrade — only UPGRADER_ROLE
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice ERC-165 interface detection.
    /// @dev    Declares conformance to ERC-4626 (sync deposit + the spec
    ///         surface that doesn't depend on sync withdraw) and the two
    ///         relevant ERC-7540 sub-interfaces (Operator + Redeem). The
    ///         async-deposit half of ERC-7540 is intentionally not declared.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return
            interfaceId == type(IERC4626).interfaceId ||
            interfaceId == type(IERC7540Operator).interfaceId ||
            interfaceId == type(IERC7540Redeem).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @dev Per-controller index of request IDs that have non-zero bilSettled.
    ///      Populated by QueueLib.processQueue on the 0 → >0 settle transition,
    ///      popped by QueueLib.claimByShares / claimByAssets when an entry is
    ///      fully claimed or stale. Replaces the previous full-queue linear
    ///      scan in claim paths, making claim gas bounded by the controller's
    ///      own outstanding settled requests (not by queueTail). Mitigates a
    ///      cancel-spam DoS that bloated queueTail with deleted slots.
    mapping(address => uint256[]) internal _settledByController;

    /// @notice Circuit-breaker threshold (bps) for Decentral payout drift on
    ///         the yield- and principal-execute branches of `pokeDecentral`.
    ///         A shortfall above this threshold reverts the call (audit H-02
    ///         defense in depth — see `setPrincipalMismatchBpsThreshold`).
    ///         Default 100 (1%). Bounded to [0, 10_000].
    uint256 public principalMismatchBpsThreshold;

    /// @dev Min-heap of packed (maturityTime, positionIndex) entries.
    uint256[] private _maturityHeap;

    /// @notice Aggregate hDCL across all requests' `bilSettled` (rate-locked,
    ///         awaiting claim). Settled shares are economically exited — they
    ///         carry a fixed HOLLAR claim (`hollarOwed`, held in
    ///         `totalReservedHollar`) and no longer earn yield — but they
    ///         remain in `totalSupply()` until claim burns them. Excluding
    ///         them (and their reserved HOLLAR) from the exchange-rate math
    ///         is what keeps the rate a pure ACTIVE-share rate: without this,
    ///         lingering settled shares blend a fixed claim against still-
    ///         accruing active shares and depress the rate for active holders
    ///         (Pashov High — settled-share dilution).
    uint256 public totalSettledBil;

    // ═══════════════════════════════════════════════════════════════════════
    //                         STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reserved storage slots for future upgrades.
    uint256[46] private __gap;
}
