// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAavePool} from "./interfaces/IAavePool.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {ISubLoop} from "./interfaces/ISubLoop.sol";
import {ISyntheticToken} from "./interfaces/ISyntheticToken.sol";

/// @title CollateralVault
/// @notice One per supported volatile collateral (ETH, tBTC, DOT…). An ERC4626
///         vault: "deposit ETH → pETH shares; redeem → ETH + yield". Non-rebasing
///         exchange-rate model (share value = totalAssets / supply, denominated
///         in the collateral), so harvested yield compounded into the Main
///         position lifts the share price — hence "deposit X, earn more X".
///
/// @dev    Architecture A. On deposit the vault:
///           1. supplies collateral to the Aave money market (Main position),
///           2. borrows HOLLAR at the target LTV,
///           3. mints + supplies SyntheticToken (= HOLLAR debt) → Main HF floored
///              → principal un-liquidatable at any collateral price,
///           4. routes the borrowed HOLLAR into the shared SubLoop.
///         Withdraw reverses it (flash-assisted unwind of the loop slice, repay
///         HOLLAR, burn synthetic, withdraw collateral). A target-LTV band keeps
///         the loop sized to the collateral value as price moves.
///
///         Patterned on HDCLVault. STATUS: structured skeleton — the Aave call
///         sequences and loop wiring are marked TODO(impl).
contract CollateralVault is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;
    uint256 internal constant VARIABLE_RATE = 2;
    uint256 private constant DEAD_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(0xdead);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ── config ────────────────────────────────────────────────────────────
    IERC20 public collateral; // the deposited asset (ETH/tBTC/…)
    IAavePool public pool;
    ISubLoop public subLoop;
    ISwapper public swapper;
    IERC20 public hollar;
    ISyntheticToken public synthetic;
    IERC20 public collateralAToken; // Aave aToken for the collateral (Main position)
    IERC20 public hollarDebtToken; // Aave variable-debt token for HOLLAR (Main debt)

    // ── policy params (→ governance / pallet-parameters analogue) ───────────
    uint16 public targetLtvBps; // e.g. 7400 for ETH (a touch under the 7500 max)
    uint16 public ltvBandLowBps; // rebalance up when LTV drifts below
    uint16 public ltvBandHighBps; // rebalance down when LTV drifts above
    uint16 public synthLtBps; // synthetic reserve's liquidation threshold (e.g. 9800)
    uint256 public tvlCap; // deposit-side cap (collateral units)
    bool public depositsPaused;

    // ── accounting ──────────────────────────────────────────────────────────
    /// @notice Loop shares this vault holds in the shared SubLoop.
    uint256 public loopShares;
    /// @notice Total synthetic this vault has minted+supplied (tracks Main debt).
    uint256 public syntheticSupplied;
    /// @notice HOLLAR pulled from the loop, not yet applied to settle requests.
    uint256 public availableHollar;
    /// @notice Main HOLLAR debt still to repay from a down-rebalance de-lever
    ///         (settled ahead of the redemption queue as the loop frees HOLLAR).
    uint256 public deleverTarget;

    // ── async redemption queue (HDCL pattern; minimal inline form) ───────────
    /// @dev Production: swap for the audited HDCL QueueLib. Inline here to keep
    ///      the scaffold self-contained. Each request snapshots its share of the
    ///      Main position at request time so settlement is deterministic.
    struct Redemption {
        address owner; // who claims the collateral
        uint256 shares; // pVault shares escrowed
        uint256 collateralOwed; // collateral to release on settle
        uint256 debtShare; // Main HOLLAR debt to repay (≈ loop equity freed)
        uint256 synthShare; // synthetic to release+burn
        uint256 repaid; // Main debt repaid so far (proportional settle)
        uint256 collateralSettled; // collateral freed + ready to claim
        bool active;
    }

    mapping(uint256 => Redemption) public redemptions;
    uint256 public queueHead; // first unsettled request
    uint256 public queueTail; // next request id
    uint256 public totalQueuedShares;

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event RedeemSettled(uint256 indexed requestId, uint256 collateral);
    event Claimed(uint256 indexed requestId, address indexed receiver, uint256 collateral);
    event Harvested(uint256 collateralCompounded);
    event Rebalanced(uint256 ltvBefore, uint256 ltvAfter);
    event SyntheticPegMaintained(int256 delta);

    error ZeroAddress();
    error ZeroAmount();
    error DepositsArePaused();
    error ExceedsTvlCap();
    error DepositTooSmall();
    error PrincipalShortfall(); // withdraw invariant: collateral out >= collateral in
    error NotRequestOwner();
    error RequestNotActive();
    error NothingToClaim();
    error PrincipalNotFloored(); // INV-1: synth*LT must cover Main debt

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address _collateral,
        address _pool,
        address _subLoop,
        address _swapper,
        address _hollar,
        address _synthetic,
        address _collateralAToken,
        address _hollarDebtToken,
        uint16 _targetLtvBps,
        uint16 _synthLtBps,
        uint256 _tvlCap,
        address _admin
    ) external initializer {
        if (_collateral == address(0) || _pool == address(0) || _admin == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        collateral = IERC20(_collateral);
        pool = IAavePool(_pool);
        subLoop = ISubLoop(_subLoop);
        swapper = ISwapper(_swapper);
        hollar = IERC20(_hollar);
        synthetic = ISyntheticToken(_synthetic);
        collateralAToken = IERC20(_collateralAToken);
        hollarDebtToken = IERC20(_hollarDebtToken);

        targetLtvBps = _targetLtvBps;
        ltvBandLowBps = _targetLtvBps > 500 ? _targetLtvBps - 500 : 0;
        ltvBandHighBps = _targetLtvBps + 300;
        synthLtBps = _synthLtBps;
        tvlCap = _tvlCap;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         CORE ACCOUNTING
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Total collateral-denominated assets backing the shares: the
    ///         vault's net Main-position value (collateral supplied, since the
    ///         synthetic exactly offsets the HOLLAR debt) plus its share of the
    ///         loop equity, valued back into the collateral asset.
    /// @dev    TODO(impl): read the Main aToken balance for `collateral`, and
    ///         convert `subLoop.equityOf(this)` (HOLLAR) into collateral units
    ///         via the oracle. The synthetic↔debt offset nets to ~0 by design.
    function totalAssets() public view returns (uint256) {
        // Net principal in collateral units ≈ the collateral supplied to the
        // Main position: the loop equity offsets the Main HOLLAR debt (the
        // borrowed HOLLAR became the loop seed), and the synthetic is a non-cash
        // HF prop. Harvested yield is supplied as more collateral → aToken grows
        // → share price rises ("deposit X, earn X").
        return collateralAToken.balanceOf(address(this));
    }

    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        return (totalAssets() * WAD) / supply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 totalA = totalAssets();
        if (supply == 0 || totalA == 0) return assets;
        return (assets * supply) / totalA;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    function asset() external view returns (address) {
        return address(collateral);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         USER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    /// @notice ERC4626 deposit. Pulls `assets` collateral, opens/extends the
    ///         leveraged position, mints shares to `receiver`.
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (depositsPaused) revert DepositsArePaused();
        if (assets == 0) revert ZeroAmount();
        if (totalAssets() + assets > tvlCap) revert ExceedsTvlCap();

        shares = _previewShares(assets); // from pre-deposit totalAssets
        if (totalSupply() == 0) _mint(DEAD_ADDRESS, DEAD_SHARES);
        _mint(receiver, shares);

        // 1. Supply the collateral to the Main Aave position.
        (uint256 collBefore8, , , , , ) = pool.getUserAccountData(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), assets);
        collateral.forceApprove(address(pool), 0);
        collateral.forceApprove(address(pool), assets);
        pool.supply(address(collateral), assets, address(this), 0);

        // 2. Borrow HOLLAR at target LTV against the collateral JUST supplied —
        //    the DELTA in account collateral value, not the total. Sizing off the
        //    total over-borrows on incremental deposits (the existing position,
        //    incl. the LTV-0 synthetic, inflates collBase8) → Aave error 36
        //    COLLATERAL_CANNOT_COVER_NEW_BORROW. (collateral USD 8dp → HOLLAR 18dp @ $1.)
        (uint256 collAfter8, , , , , ) = pool.getUserAccountData(address(this));
        uint256 borrowHollar = ((collAfter8 - collBefore8) * targetLtvBps) / BPS * 1e10;

        pool.borrow(address(hollar), borrowHollar, VARIABLE_RATE, 0, address(this));

        // 3. Mint synthetic sized so synth·LT > debt — floors the Main HF
        //    strictly ABOVE 1 from the synthetic *alone*, so the principal is
        //    un-liquidatable at any collateral price (the +0.5% buffer keeps it
        //    clear of the boundary through rounding/8dp-base truncation). LTV 0
        //    ⇒ the synthetic adds no borrow power.
        uint256 synthAmt = (borrowHollar * BPS + synthLtBps - 1) / synthLtBps;
        synthAmt += synthAmt / 200; // +0.5% buffer
        syntheticSupplied += synthAmt;
        synthetic.mint(address(this), synthAmt);
        IERC20(address(synthetic)).forceApprove(address(pool), 0);
        IERC20(address(synthetic)).forceApprove(address(pool), synthAmt);
        pool.supply(address(synthetic), synthAmt, address(this), 0);

        // 4. Route the borrowed HOLLAR into the shared loop.
        hollar.forceApprove(address(subLoop), 0);
        hollar.forceApprove(address(subLoop), borrowHollar);
        loopShares += subLoop.deposit(borrowHollar);

        // INV-1 (on-chain guard): the synthetic alone must cover the Main debt,
        // so the principal is un-liquidatable at any collateral price.
        if (syntheticSupplied * synthLtBps / BPS < hollarDebtToken.balanceOf(address(this))) {
            revert PrincipalNotFloored();
        }
        emit Deposited(receiver, assets, shares);
    }

    /// @notice ERC-7540-style async redemption. Escrows `shares`, asks the
    ///         shared SubLoop to unwind the matching loop-equity slice, and
    ///         enqueues a request the SubLoop's deleveraging spiral settles over
    ///         blocks. Claim collateral via `claim` once settled.
    /// @dev    Async because the loop unwinds gradually via DCA (see SubLoop).
    function requestRedeem(uint256 shares, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        uint256 supply = totalSupply();

        // Snapshot this request's proportional share of the Main position so
        // settlement is deterministic regardless of later flows.
        uint256 collateralOwed = (collateralAToken.balanceOf(address(this)) * shares) / supply;
        uint256 debtShare = (hollarDebtToken.balanceOf(address(this)) * shares) / supply;
        uint256 synthShare = (syntheticSupplied * shares) / supply;
        uint256 loopSlice = (loopShares * shares) / supply;

        // Escrow the pVault shares.
        _transfer(owner, address(this), shares);

        // Ask the shared loop to unwind this vault's proportional equity slice.
        loopShares -= loopSlice;
        subLoop.requestUnwind(loopSlice);

        requestId = queueTail++;
        redemptions[requestId] = Redemption({
            owner: owner,
            shares: shares,
            collateralOwed: collateralOwed,
            debtShare: debtShare,
            synthShare: synthShare,
            repaid: 0,
            collateralSettled: 0,
            active: true
        });
        totalQueuedShares += shares;
        emit RedeemRequested(requestId, owner, shares);
    }

    /// @notice Keeper settlement: pull equity HOLLAR the SubLoop's deleveraging
    ///         spiral has freed, then settle queued requests FIFO. For each
    ///         request, repay its Main debt slice, release+burn its synthetic,
    ///         withdraw its collateral, and mark it claimable.
    function pokeSettle() external onlyRole(KEEPER_ROLE) nonReentrant {
        availableHollar += subLoop.pullFreed();

        // De-lever repayments (down-rebalance) settle first: repay Main debt and
        // burn synthetic proportionally (ratio — hence the buffer — preserved).
        if (deleverTarget > 0 && availableHollar > 0) {
            uint256 r = availableHollar < deleverTarget ? availableHollar : deleverTarget;
            uint256 debtNow = hollarDebtToken.balanceOf(address(this));
            uint256 synthBurn = debtNow == 0 ? 0 : (syntheticSupplied * r) / debtNow;
            availableHollar -= r;
            deleverTarget -= r;
            hollar.forceApprove(address(pool), 0);
            hollar.forceApprove(address(pool), r);
            pool.repay(address(hollar), r, VARIABLE_RATE, address(this));
            if (synthBurn > 0) {
                pool.withdraw(address(synthetic), synthBurn, address(this));
                synthetic.burn(address(this), synthBurn);
                syntheticSupplied -= synthBurn;
            }
        }

        uint256 head = queueHead;
        while (head < queueTail && availableHollar > 0) {
            Redemption storage r = redemptions[head];
            uint256 remainingDebt = r.active ? r.debtShare - r.repaid : 0;
            if (remainingDebt == 0) {
                head++;
                continue;
            }
            // Repay as much of this request's debt as is currently freed, and
            // release collateral + synthetic PROPORTIONALLY (partial-safe; robust
            // to unwind dust). HF stays safe — collateral leaves in lockstep with
            // the debt it backed, the synthetic still floors the remainder.
            uint256 repayNow = availableHollar < remainingDebt ? availableHollar : remainingDebt;
            availableHollar -= repayNow;
            hollar.forceApprove(address(pool), 0);
            hollar.forceApprove(address(pool), repayNow);
            pool.repay(address(hollar), repayNow, VARIABLE_RATE, address(this));

            uint256 synthRel = (r.synthShare * repayNow) / r.debtShare;
            if (synthRel > 0) {
                pool.withdraw(address(synthetic), synthRel, address(this));
                synthetic.burn(address(this), synthRel);
                syntheticSupplied -= synthRel;
            }
            uint256 collRel = (r.collateralOwed * repayNow) / r.debtShare;
            pool.withdraw(address(collateral), collRel, address(this));
            r.collateralSettled += collRel;
            r.repaid += repayNow;

            emit RedeemSettled(head, collRel);
            if (r.repaid >= r.debtShare) head++;
            else break; // wait for more freed equity
        }
        queueHead = head;
    }

    /// @notice Claim settled collateral for a request.
    function claim(uint256 requestId, address receiver) external nonReentrant returns (uint256 amountOut) {
        if (receiver == address(0)) revert ZeroAddress();
        Redemption storage r = redemptions[requestId];
        if (!r.active) revert RequestNotActive();
        if (msg.sender != r.owner) revert NotRequestOwner();
        amountOut = r.collateralSettled;
        if (amountOut == 0) revert NothingToClaim();

        r.collateralSettled = 0;
        r.active = false;
        totalQueuedShares -= r.shares;
        _burn(address(this), r.shares); // burn the escrowed pVault shares
        collateral.safeTransfer(receiver, amountOut);
        emit Claimed(requestId, receiver, amountOut);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         KEEPER OPERATIONS
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Compound this vault's share of harvested loop carry into the
    ///         collateral, lifting the share price ("deposit X, earn X"). The
    ///         Harvester pulls the vault's cut from the loop and calls this with
    ///         the harvested token (PRIME) to swap into collateral and supply.
    function compound(address tokenIn, uint256 amountIn, uint256 minCollateralOut, bytes calldata route)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        if (amountIn == 0) revert ZeroAmount();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(swapper), 0);
        IERC20(tokenIn).forceApprove(address(swapper), amountIn);
        uint256 out = swapper.sell(tokenIn, address(collateral), amountIn, minCollateralOut, route);
        collateral.forceApprove(address(pool), 0);
        collateral.forceApprove(address(pool), out);
        pool.supply(address(collateral), out, address(this), 0); // → aToken grows → share price ↑
        emit Harvested(out);
    }

    /// @notice Rebalance the Main position back into the target-LTV band after a
    ///         collateral price move: borrow more (price up) or repay (price down),
    ///         growing/shrinking the loop and the synthetic in lockstep.
    function rebalance() external onlyRole(KEEPER_ROLE) nonReentrant {
        // Isolate the collateral leg's LTV: collBase8 = ETH value + synth value,
        // and synth value = syntheticSupplied (both $1), so ETH value backs out
        // without a separate oracle ref.
        (uint256 collBase8, uint256 debtBase8, , , , ) = pool.getUserAccountData(address(this));
        uint256 synthValue8 = syntheticSupplied / 1e10;
        uint256 ethValue8 = collBase8 > synthValue8 ? collBase8 - synthValue8 : 0;
        if (ethValue8 == 0) {
            emit Rebalanced(0, 0);
            return;
        }
        uint256 ltvBefore = (debtBase8 * BPS) / ethValue8;

        if (ltvBefore < ltvBandLowBps) {
            // Collateral appreciated → borrow up to target and deploy the slack,
            // so the yield notional tracks the collateral value.
            uint256 targetDebt8 = (ethValue8 * targetLtvBps) / BPS;
            uint256 addHollar = (targetDebt8 - debtBase8) * 1e10;
            if (addHollar == 0) {
                emit Rebalanced(ltvBefore, ltvBefore);
                return;
            }
            pool.borrow(address(hollar), addHollar, VARIABLE_RATE, 0, address(this));

            uint256 addSynth = (addHollar * BPS + synthLtBps - 1) / synthLtBps;
            addSynth += addSynth / 200;
            syntheticSupplied += addSynth;
            synthetic.mint(address(this), addSynth);
            IERC20(address(synthetic)).forceApprove(address(pool), 0);
            IERC20(address(synthetic)).forceApprove(address(pool), addSynth);
            pool.supply(address(synthetic), addSynth, address(this), 0);

            hollar.forceApprove(address(subLoop), 0);
            hollar.forceApprove(address(subLoop), addHollar);
            loopShares += subLoop.deposit(addHollar);
        } else if (ltvBefore > ltvBandHighBps) {
            // Collateral fell → over-levered on the real ETH. De-lever: unwind the
            // loop slice that frees the excess debt's worth of equity; `pokeSettle`
            // repays Main debt + burns synth from it (ahead of the redeem queue).
            // NOT safety-critical — the synthetic still floors Main HF ≥ 1; this
            // restores the real-collateral backing ratio (and trims yield-side risk).
            uint256 targetDebt8 = (ethValue8 * targetLtvBps) / BPS;
            uint256 repay8 = debtBase8 - targetDebt8;
            uint256 loopEq8 = subLoop.equityOf(address(this));
            uint256 sliceShares = loopEq8 == 0 ? 0 : (loopShares * repay8) / loopEq8;
            if (sliceShares > loopShares) sliceShares = loopShares;
            if (sliceShares > 0) {
                loopShares -= sliceShares;
                subLoop.requestUnwind(sliceShares);
                deleverTarget += repay8 * 1e10;
            }
        }
        (uint256 c2, uint256 d2, , , , ) = pool.getUserAccountData(address(this));
        uint256 ev2 = c2 > syntheticSupplied / 1e10 ? c2 - syntheticSupplied / 1e10 : 0;
        emit Rebalanced(ltvBefore, ev2 == 0 ? 0 : (d2 * BPS) / ev2);
    }

    /// @notice Keep `synth·LT ≥ Main debt` as the HOLLAR debt accrues interest —
    ///         re-tops the synthetic so the principal stays un-liquidatable.
    function maintainPeg() external onlyRole(KEEPER_ROLE) nonReentrant {
        uint256 debt = hollarDebtToken.balanceOf(address(this));
        uint256 required = (debt * BPS + synthLtBps - 1) / synthLtBps;
        required += required / 200; // +0.5% buffer (matches deposit)
        if (syntheticSupplied >= required) {
            emit SyntheticPegMaintained(0);
            return;
        }
        uint256 add = required - syntheticSupplied;
        syntheticSupplied += add;
        synthetic.mint(address(this), add);
        IERC20(address(synthetic)).forceApprove(address(pool), 0);
        IERC20(address(synthetic)).forceApprove(address(pool), add);
        pool.supply(address(synthetic), add, address(this), 0);
        emit SyntheticPegMaintained(int256(add));
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         INTERNAL / ADMIN
    // ══════════════════════════════════════════════════════════════════════

    function _previewShares(uint256 assets) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (assets <= DEAD_SHARES) revert DepositTooSmall();
            return assets - DEAD_SHARES;
        }
        uint256 totalA = totalAssets();
        shares = totalA == 0 ? assets : (assets * supply) / totalA;
        if (shares == 0) revert DepositTooSmall();
    }

    function setLtvBand(uint16 target, uint16 low, uint16 high) external onlyRole(ADMIN_ROLE) {
        targetLtvBps = target;
        ltvBandLowBps = low;
        ltvBandHighBps = high;
    }

    function setTvlCap(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        tvlCap = newCap;
    }

    function pauseDeposits() external onlyRole(GUARDIAN_ROLE) {
        depositsPaused = true;
    }

    function unpauseDeposits() external onlyRole(GUARDIAN_ROLE) {
        depositsPaused = false;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[39] private __gap;
}
