// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAavePool, IPoolAddressesProvider, IAaveOracle} from "./interfaces/IAavePool.sol";
import {ISubLoop} from "./interfaces/ISubLoop.sol";
import {IYieldSource, ILeveragedLoop} from "./interfaces/IYieldSource.sol";
import {DcaDispatch} from "./lib/DcaDispatch.sol";

/// @title SubLoop
/// @notice The single shared leveraged PRIME/HOLLAR loop (Aave isolation mode).
///         Deploy and unwind are **gradual and async**:
///
///         DEPLOY ── keeper `pokeBorrow`: borrow an HF-safe HOLLAR tranche, then
///           router-sell HOLLAR ─▶ aPRIME (swap+supply folded via the Aave
///           trade-executor route) in the same call. The loop self-ramps to
///           target HF over repeated pokes, then borrowing dries up.
///
///         UNWIND ── the deleveraging spiral: keeper `pokeRepay` router-sells an
///           HF-safe aPRIME sliver ─▶ HOLLAR (withdraw+swap folded) and repays
///           loop debt with the proceeds, raising HF and reopening the next
///           sliver. Most of each tranche repays the loop's own debt; the
///           ~1/leverage equity portion is credited to the unwinding vault,
///           which pulls it to settle its own (HDCL-style) redemption queue.
///           de-lever uses the same spiral with the FULL proceeds repaying debt.
///
///         No flash loans. Every swap, incl. the Aave supply/withdraw (aTokens
///         are routable), executes synchronously through pallet_route::sell via
///         the dispatch precompile (DcaDispatch.routerSell) with an
///         AaveOracle-fair min-out; gradualness comes from the keeper's
///         tranche-capped poke cadence.
contract SubLoop is
    ISubLoop,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant VARIABLE_RATE = 2;
    /// @dev per-step HF floor for the unwind spiral's aPRIME withdraw — just
    ///      above Aave's ~1.0 hard limit so the in-route withdraw never reverts;
    ///      the repay that follows lifts HF back toward target.
    uint256 internal constant STEP_HF_FLOOR = 1.02e18;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Registered CollateralVaults — the only callers of deposit/unwind.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    // KEEPER_ROLE removed: pokeBorrow/pokeRepay/harvest/deLever are permissionless
    // (bounded, oracle-priced, no caller payout). harvest pays the stored harvester.

    // ── config ────────────────────────────────────────────────────────────
    IAavePool public pool;
    IERC20 public hollar;
    IERC20 public prime;
    IERC20 public primeAToken; // collateral receipt (this loop's Aave position)
    /// @notice Recipient of harvested surplus PRIME (the Harvester). With
    ///         harvest permissionless, the payout pins here regardless of caller.
    address public harvester;

    // ── policy params ─────────────────────────────────────────────────────
    uint256 public targetHf; // e.g. 1.05e18
    uint256 public deployHfFloor; // borrow only while HF would stay >= this (≥ target, swap-lag buffer)
    uint256 public deLeverTrigger; // e.g. 1.10e18
    uint256 public harvestThreshold; // WAD fraction of equity
    uint256 public deployTranche; // HOLLAR per pokeBorrow lever-in
    uint256 public unwindTranche; // aPRIME per pokeRepay sell sliver

    // ── router route config (HOLLAR↔aPRIME), set by admin ───────────────────
    uint32 public hollarAssetId; // 222
    uint32 public primeAssetId; // 43
    uint32 public aPrimeAssetId; // 1043
    uint32 public primePoolId; // stableswap 143 (HOLLAR↔PRIME)
    uint32 public dcaSlippagePpm; // Permill slippage vs the oracle-fair min-out

    // ── equity shares ─────────────────────────────────────────────────────
    mapping(address => uint256) internal _sharesOf;
    uint256 internal _totalShares;
    /// @notice Principal (cost-basis) equity, HOLLAR 18dp — the seed deposited,
    ///         net of unwinds. Equity above this is harvestable carry (yield).
    uint256 public principalEquity;

    // ── unwind / de-lever state ───────────────────────────────────────────
    uint256 public unwindTargetEquity; // total equity (HOLLAR, 18dp) being unwound
    mapping(address => uint256) public unwindRequested; // per-vault equity targeted (18dp)
    mapping(address => uint256) public freedHollar; // per-vault equity freed, not yet pulled (18dp)
    uint256 public reservedFreed; // Σ freedHollar (HOLLAR held back for vaults to pull)
    uint256 public unwindOrderId;
    address[] internal _unwinders; // vaults with an open unwind request
    mapping(address => bool) internal _isUnwinding;
    /// @notice Outstanding safety de-lever debt repay (HOLLAR 18dp). Set by
    ///         deLever, drained by pokeRepay ahead of the proportional split.
    uint256 public deleverDebtTarget;

    event LoopDeposited(address indexed vault, uint256 hollarIn, uint256 shares);
    event UnwindRequested(address indexed vault, uint256 shares, uint256 equity, uint256 unwindId);
    event FreedPulled(address indexed vault, uint256 hollar);
    event Borrowed(uint256 amount, uint256 hfAfter);
    event Repaid(uint256 amount, uint256 hfAfter);
    event Harvested(uint256 surplus);
    event DeLevered(uint256 hfBefore, uint256 hfAfter);
    /// @notice The spiral ran the position to zero collateral with unwind targets
    ///         still open; the unrealizable remainder was written off.
    event UnwindClosedOut(uint256 unrealizedEquity);

    error ZeroAmount();
    error ZeroAddress();
    error HealthyEnough();
    error InsufficientShares();
    error HarvesterUnset();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _pool,
        address _hollar,
        address _prime,
        address _primeAToken,
        uint256 _targetHf,
        uint256 _deLeverTrigger,
        address _admin
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        pool = IAavePool(_pool);
        hollar = IERC20(_hollar);
        prime = IERC20(_prime);
        primeAToken = IERC20(_primeAToken);

        targetHf = _targetHf;
        deLeverTrigger = _deLeverTrigger;
        deployHfFloor = _targetHf; // borrow down to target; swap lag keeps actual HF above
        harvestThreshold = 1e15; // 0.1%

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        // Grant GUARDIAN_ROLE (the emergency pause) to the admin so the pause is
        // never wired to a role nobody holds; governance can delegate it to a
        // faster-path holder (the technical committee) afterwards.
        _grantRole(GUARDIAN_ROLE, _admin);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         VAULT-FACING
    // ══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IYieldSource
    function deposit(uint256 hollarAmount)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (hollarAmount == 0) revert ZeroAmount();
        hollar.safeTransferFrom(msg.sender, address(this), hollarAmount);

        // Shares price off current NAV. Work in HOLLAR 18dp throughout: equity
        // from getUserAccountData is 8dp USD → ×1e10. First deposit ⇒ 1 share
        // per HOLLAR of seed; later deposits dilute against accrued NAV.
        uint256 equityBasis18 = totalEquity() * 1e10;
        shares = (_totalShares == 0 || equityBasis18 == 0)
            ? hollarAmount
            : (hollarAmount * _totalShares) / equityBasis18;
        _sharesOf[msg.sender] += shares;
        _totalShares += shares;
        principalEquity += hollarAmount; // cost basis (seed)

        // FUTURE(matching): before funding the deploy DCA, match against
        //   outstanding unwindTargetEquity — pay an exiting vault directly from
        //   this incoming HOLLAR and transfer its loop shares at NAV, skipping
        //   both DCAs for the matched amount (see README → Future improvements).
        _fundDeploy(hollarAmount);
        emit LoopDeposited(msg.sender, hollarAmount, shares);
    }

    /// @inheritdoc IYieldSource
    function requestUnwind(uint256 shares)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 unwindId)
    {
        uint256 held = _sharesOf[msg.sender];
        if (shares == 0) revert ZeroAmount();
        if (shares > held) revert InsufficientShares();

        uint256 totalSharesBefore = _totalShares;
        // Equity (8dp USD) of this slice → HOLLAR (18dp, $1) for payout accounting.
        uint256 equity8 = totalSharesBefore == 0 ? 0 : (totalEquity() * shares) / totalSharesBefore;
        uint256 equityHollar = equity8 * 1e10;

        principalEquity -= (principalEquity * shares) / totalSharesBefore; // shrink cost basis
        _sharesOf[msg.sender] = held - shares;
        _totalShares -= shares;

        if (!_isUnwinding[msg.sender]) {
            _isUnwinding[msg.sender] = true;
            _unwinders.push(msg.sender);
        }
        unwindRequested[msg.sender] += equityHollar;
        unwindTargetEquity += equityHollar;

        // The unwind spiral is driven synchronously by the keeper in pokeRepay:
        // it router-sells an HF-safe aPRIME sliver → HOLLAR each call. pallet-DCA
        // can't price the aToken (aPRIME trades in no pool → no oracle entry →
        // CalculatingPriceError), but pallet_route::sell executes via pool
        // reserves with a caller-set min-out, no oracle valuation. So we record
        // the request here and let pokeRepay grind it down.
        unwindId = ++unwindOrderId;
        emit UnwindRequested(msg.sender, shares, equityHollar, unwindId);
    }

    /// @inheritdoc IYieldSource
    function pullFreed() external override onlyRole(VAULT_ROLE) nonReentrant returns (uint256 hollarSent) {
        hollarSent = freedHollar[msg.sender];
        if (hollarSent == 0) return 0;
        freedHollar[msg.sender] = 0;
        reservedFreed -= hollarSent;
        if (unwindRequested[msg.sender] >= hollarSent) {
            unwindRequested[msg.sender] -= hollarSent;
        } else {
            unwindRequested[msg.sender] = 0;
        }
        // prune finished unwinders so _creditFreed's loop doesn't grow unbounded
        if (unwindRequested[msg.sender] == 0) _pruneUnwinder(msg.sender);
        hollar.safeTransfer(msg.sender, hollarSent);
        emit FreedPulled(msg.sender, hollarSent);
    }

    /// @dev swap-remove `vault` from `_unwinders` and clear its flag. Called
    ///      once its outstanding request hits zero; a later requestUnwind
    ///      re-registers it.
    function _pruneUnwinder(address vault) internal {
        if (!_isUnwinding[vault]) return;
        _isUnwinding[vault] = false;
        uint256 n = _unwinders.length;
        for (uint256 i = 0; i < n; i++) {
            if (_unwinders[i] == vault) {
                _unwinders[i] = _unwinders[n - 1];
                _unwinders.pop();
                return;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         KEEPER (debt legs only)
    // ══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ILeveragedLoop
    /// @dev permissionless: the call is fully bounded — borrows only down to
    ///      deployHfFloor, caps the amount at deployTranche, and swaps with an
    ///      oracle-fair minOut. A caller can only advance the ramp (or waste gas
    ///      on a no-op at floor), never extract value, so no role is needed.
    function pokeBorrow() external override nonReentrant whenNotPaused {
        // The DCA's Aave hop mints aPRIME to this loop but does not flip the
        // use-as-collateral flag, so without this the loop's borrow power stays 0.
        // Enable PRIME as collateral once it holds aPRIME (Aave no-ops if already on).
        if (primeAToken.balanceOf(address(this)) > 0) {
            pool.setUserUseReserveAsCollateral(address(prime), true);
        }
        // Borrow against CURRENT collateral so the DCA lag never dips HF below
        // the floor. Aave HF = collWithLT / debt; max debt at the floor is
        //   maxDebt = collBase·wAvgLT / deployHfFloor.
        (uint256 collBase8, uint256 debtBase8, , uint256 wAvgLtBps, , ) =
            pool.getUserAccountData(address(this));
        uint256 collWithLt8 = (collBase8 * wAvgLtBps) / 1e4; // 8dp USD
        uint256 maxDebt8 = (collWithLt8 * WAD) / deployHfFloor; // 8dp USD
        if (maxDebt8 <= debtBase8) {
            emit Borrowed(0, healthFactor());
            return;
        }
        // HOLLAR is 18dp and $1 ⇒ amount(18dp) = borrowBase(8dp) · 1e10.
        uint256 borrowHollar = (maxDebt8 - debtBase8) * 1e10;
        // Cap per call to deployTranche: _fundDeploy sells synchronously via the
        // router, so a borrow-to-floor in one shot would dump the whole amount
        // into pool-143 and trip slippage. Tranche it — the keeper calls
        // pokeBorrow repeatedly to ramp (gradual, like the old deploy DCA).
        if (deployTranche > 0 && borrowHollar > deployTranche) borrowHollar = deployTranche;
        if (borrowHollar == 0) {
            emit Borrowed(0, healthFactor());
            return;
        }
        pool.borrow(address(hollar), borrowHollar, VARIABLE_RATE, 0, address(this));
        _fundDeploy(borrowHollar);
        emit Borrowed(borrowHollar, healthFactor());
    }

    /// @dev Synchronous HOLLAR→aPRIME via pallet_route::sell (no DCA). The route
    ///      folds the stableswap swap + Aave supply, so the loop receives aPRIME
    ///      collateral in-call. Gradualness comes from the keeper's HF-capped
    ///      `pokeBorrow` cadence (each call borrows only up to the deploy floor,
    ///      then levers that sliver). router.sell executes via pool reserves with
    ///      a caller-set min-out — no EMA-oracle valuation, no priceability
    ///      constraint, no schedule lifecycle to babysit.
    function _fundDeploy(uint256 amount) internal {
        if (amount == 0) return;
        // min-out off the AaveOracle fair rate (manipulation-resistant), NOT a
        // hardcoded 1:1 — PRIME ≠ HOLLAR in value. aPRIME is 1:1 with PRIME.
        // fair aPRIME (6dp) = amount HOLLAR (18dp) · pHollar/pPrime, /1e12 decimals.
        (uint256 pHollar, uint256 pPrime) = _oracleRate();
        uint256 fairOut = (amount * pHollar) / pPrime / 1e12;
        uint128 minOut = uint128((fairOut * (1_000_000 - dcaSlippagePpm)) / 1_000_000);
        DcaDispatch.routerSell(hollarAssetId, aPrimeAssetId, uint128(amount), minOut, _deployRoute());
    }

    /// @dev (pHollar, pPrime) from the market's AaveOracle (USD, 8dp) — the same
    ///      feed Aave uses for HF, so swap min-outs resist pool-spot manipulation.
    function _oracleRate() internal view returns (uint256 pHollar, uint256 pPrime) {
        address oracle = IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle();
        pHollar = IAaveOracle(oracle).getAssetPrice(address(hollar));
        pPrime = IAaveOracle(oracle).getAssetPrice(address(prime));
    }

    /// @dev HOLLAR →[stableswap primePoolId]→ PRIME →[Aave]→ aPRIME.
    function _deployRoute() internal view returns (DcaDispatch.Hop[] memory r) {
        r = new DcaDispatch.Hop[](2);
        r[0] = DcaDispatch.Hop(DcaDispatch.POOL_STABLESWAP, true, primePoolId, hollarAssetId, primeAssetId);
        r[1] = DcaDispatch.Hop(DcaDispatch.POOL_AAVE, false, 0, primeAssetId, aPrimeAssetId);
    }

    /// @dev aPRIME →[Aave]→ PRIME →[stableswap primePoolId]→ HOLLAR.
    function _unwindRoute() internal view returns (DcaDispatch.Hop[] memory r) {
        r = new DcaDispatch.Hop[](2);
        r[0] = DcaDispatch.Hop(DcaDispatch.POOL_AAVE, false, 0, aPrimeAssetId, primeAssetId);
        r[1] = DcaDispatch.Hop(DcaDispatch.POOL_STABLESWAP, true, primePoolId, primeAssetId, hollarAssetId);
    }

    /// @inheritdoc ILeveragedLoop
    function pokeRepay() external override nonReentrant {
        // Did this round have HF headroom to sell into, and did it actually sell?
        // The two together separate a PERMANENT truncation stall (headroom exists
        // but the sliver floors to 0 in 6dp aPRIME — it can only ever shrink) from
        // a TEMPORARY HF block (no headroom; a price move or a repay reopens it).
        bool budgetExists;
        bool sold;
        // UNWIND SPIRAL STEP: while an unwind is open, synchronously sell an
        // HF-safe sliver of aPRIME → HOLLAR via the router (no DCA — the router
        // executes through pool reserves with a min-out, so the unpriceable
        // aToken is fine). The withdraw inside the route dips HF toward Aave's
        // ~1.0 limit; we cap the sliver to keep HF ≥ STEP_HF_FLOOR (1.02) so the
        // withdraw never reverts, then the repay below lifts HF back up.
        if (unwindTargetEquity > 0 || deleverDebtTarget > 0) {
            (uint256 coll8, uint256 debt8, , uint256 lt, , ) = pool.getUserAccountData(address(this));
            if (debt8 > 0 && lt > 0) {
                // min collateral to keep HF ≥ 1.02 after the withdraw:
                //   minColl8 = floor * debt8 * 1e4 / (lt_bps * WAD)
                uint256 minColl8 = (STEP_HF_FLOOR * debt8 * 10000) / (lt * WAD);
                if (coll8 > minColl8) {
                    budgetExists = true;
                    // Size the sell at the ORACLE price, not $1 (mirrors
                    // _fundDeploy/harvest): the safe USD budget (coll8 - minColl8)
                    // buys FEWER aPRIME when PRIME > $1, so the in-route withdraw
                    // never removes more collateral value than the HF floor
                    // allows. Assuming $1 oversells by the PRIME premium and dips
                    // HF below the floor (reverting the withdraw once PRIME has
                    // appreciated enough — a redemption/de-lever outage).
                    // aPRIME(6dp) = budgetUSD8 · 0.9 · 1e6 / pPrime(8dp).
                    (uint256 pHollar, uint256 pPrime) = _oracleRate();
                    uint256 sellAmt = ((coll8 - minColl8) * 90 / 100) * 1e6 / pPrime;
                    if (unwindTranche > 0 && sellAmt > unwindTranche) sellAmt = unwindTranche;
                    uint256 apBal = primeAToken.balanceOf(address(this));
                    if (sellAmt > apBal) sellAmt = apBal;
                    if (sellAmt > 0) {
                        // min-out off the AaveOracle fair rate (aPRIME 1:1 PRIME).
                        // fair HOLLAR (18dp) = sellAmt aPRIME (6dp) · pPrime/pHollar · 1e12.
                        uint256 fairOut = (sellAmt * pPrime * 1e12) / pHollar;
                        uint128 minOut = uint128((fairOut * (1_000_000 - dcaSlippagePpm)) / 1_000_000);
                        DcaDispatch.routerSell(aPrimeAssetId, hollarAssetId, uint128(sellAmt), minOut, _unwindRoute());
                        sold = true;
                    }
                }
            }
        }

        // HOLLAR the unwind spiral delivered (excludes HOLLAR already reserved
        // for vaults to pull).
        uint256 bal = hollar.balanceOf(address(this));
        uint256 avail = bal > reservedFreed ? bal - reservedFreed : 0;
        if (avail == 0) {
            // Nothing sold and nothing in hand, yet HF headroom existed: the sliver
            // floored to zero in 6dp aPRIME. That budget can only shrink, so the
            // spiral will never move again and the open unwind is unrealizable.
            if (budgetExists && !sold) _closeOutUnrealizableUnwinds();
            emit Repaid(0, healthFactor());
            return;
        }

        // Safety de-lever first: the FULL proceeds repay loop debt (no payout,
        // no proportional split — collateral already left in the sell, so each
        // repaid sliver raises HF). Equity is unchanged (coll −x, debt −x).
        uint256 deleverRepaid;
        if (deleverDebtTarget > 0) {
            deleverRepaid = avail < deleverDebtTarget ? avail : deleverDebtTarget;
            hollar.forceApprove(address(pool), 0);
            hollar.forceApprove(address(pool), deleverRepaid);
            pool.repay(address(hollar), deleverRepaid, VARIABLE_RATE, address(this));
            deleverDebtTarget -= deleverRepaid;
            avail -= deleverRepaid;
            if (avail == 0) {
                emit Repaid(deleverRepaid, healthFactor());
                return;
            }
        }

        // The DCA already withdrew the collateral that produced `avail`. Repay
        // the debt portion of that slice so the position shrinks *proportionally*
        // (HF preserved), and free the equity remainder:
        //   preColl = currentColl + avail ; repay = avail · debt/preColl.
        (uint256 collBase8, uint256 debtBase8, , , , ) = pool.getUserAccountData(address(this));
        uint256 avail8 = avail / 1e10;
        uint256 preColl8 = collBase8 + avail8;
        uint256 repay8 = preColl8 == 0 ? 0 : (avail8 * debtBase8) / preColl8;
        uint256 repayHollar = repay8 * 1e10;
        if (repayHollar > avail) repayHollar = avail;

        if (repayHollar > 0) {
            hollar.forceApprove(address(pool), 0);
            hollar.forceApprove(address(pool), repayHollar);
            pool.repay(address(hollar), repayHollar, VARIABLE_RATE, address(this));
        }

        uint256 freed = avail - repayHollar;
        if (freed > 0) _creditFreed(freed);
        // Fully drained: no collateral left to sell for anyone, ever.
        if (primeAToken.balanceOf(address(this)) == 0) _closeOutUnrealizableUnwinds();
        emit Repaid(deleverRepaid + repayHollar, healthFactor());
    }

    /// @dev The spiral records unwind targets at the ORACLE-MARKED value of the
    ///      share slice (`requestUnwind`), but funds them with the HOLLAR actually
    ///      REALIZED by selling aPRIME. The two never agree to the wei: 8dp
    ///      base-unit truncation in the proportional repay above leaves a tail even
    ///      at zero slippage, and real swap slippage or negative carry widens it.
    ///
    ///      Once the loop holds no aPRIME at all there is nothing left to sell for
    ///      anyone, so that remainder is unrealizable by construction. Leaving it
    ///      open is not harmless: `unwindRequested[v]` never decays to zero, so the
    ///      vault's `pendingUnwindOf` never clears, its redemption queue head never
    ///      advances, every request behind it is blocked, and `setYieldSource`'s
    ///      drain guard can never be satisfied. Write it down to what was realized.
    ///
    ///      Callers decide WHEN the spiral is finished; both triggers are states the
    ///      position can never leave. A temporary HF block (no headroom this round)
    ///      is deliberately NOT a trigger — a price move or a repay reopens it.
    function _closeOutUnrealizableUnwinds() internal {
        if (unwindTargetEquity == 0) return;

        for (uint256 i = _unwinders.length; i > 0; ) {
            unchecked {
                --i;
            }
            address v = _unwinders[i];
            if (unwindRequested[v] > freedHollar[v]) unwindRequested[v] = freedHollar[v];
            // Nothing credited and nothing left to credit — drop it from the loop so
            // `_creditFreed` doesn't keep walking a vault with no outstanding claim
            // (`pullFreed` would otherwise never run for it and never prune it).
            if (unwindRequested[v] == 0) _pruneUnwinder(v);
        }

        emit UnwindClosedOut(unwindTargetEquity);
        unwindTargetEquity = 0;
    }

    /// @dev Credit freed equity HOLLAR to open unwind requests, pro-rata by the
    ///      REMAINING-to-credit slice (request minus credited-but-unpulled),
    ///      capped there too. Weighting by the raw `unwindRequested` is wrong:
    ///      it only shrinks on pull while `unwindTargetEquity` shrinks on
    ///      credit, so after any credit-without-pull round req/target > 1 and
    ///      Σcut exceeds `freed` — `reservedFreed` then overstates the loop's
    ///      actual HOLLAR and pulls revert on balance. Σrem == target, so this
    ///      weighting distributes at most `freed`.
    function _creditFreed(uint256 freed) internal {
        uint256 target = unwindTargetEquity;
        if (target == 0) return;
        uint256 n = _unwinders.length;
        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            address v = _unwinders[i];
            uint256 rem = unwindRequested[v] - freedHollar[v];
            if (rem == 0) continue;
            uint256 cut = (freed * rem) / target;
            if (cut > rem) cut = rem;
            freedHollar[v] += cut;
            distributed += cut;
        }
        reservedFreed += distributed;
        // Shrink the outstanding target so the pokeRepay spiral stops once all
        // requested equity is freed (otherwise it would keep selling aPRIME).
        unwindTargetEquity = unwindTargetEquity > distributed ? unwindTargetEquity - distributed : 0;
        // Rounding dust (freed - distributed) stays as idle HOLLAR; folded into
        // the next pokeRepay's `avail`.
    }

    /// @inheritdoc IYieldSource
    /// @dev Returns PRIME (not HOLLAR): the surplus collateral skimmed above the
    ///      cost basis. The Harvester swaps it into each vault's collateral. This
    ///      keeps SubLoop swap-free — withdrawing the surplus leaves HF at target
    ///      (removed collateral was the cushion the yield created).
    function harvest() external override nonReentrant whenNotPaused returns (uint256 surplusPrime) {
        uint256 equity18 = totalEquity() * 1e10;
        // in-flight unwind equity belongs to exiting vaults: their shares are
        // already burned (principalEquity dropped) but the equity stays in the
        // loop until pokeRepay frees it. it is NOT carry — skimming it would
        // pay one vault's principal out to the others' shareholders.
        uint256 reserved18 = principalEquity + unwindTargetEquity;
        if (equity18 <= reserved18) {
            emit Harvested(0);
            return 0;
        }
        uint256 surplus18 = equity18 - reserved18;
        // guard: only harvest once carry exceeds the threshold fraction of basis
        if (principalEquity != 0 && surplus18 * WAD < principalEquity * harvestThreshold) {
            emit Harvested(0);
            return 0;
        }
        // surplus (HOLLAR 18dp) → PRIME native (6dp) at the ORACLE rate — PRIME
        // is not $1 (mirrors _fundDeploy); a /1e12 would over-withdraw by the
        // PRIME premium and dip HF below target.
        (uint256 pHollar, uint256 pPrime) = _oracleRate();
        surplusPrime = (surplus18 * pHollar) / pPrime / 1e12;
        if (surplusPrime == 0) {
            emit Harvested(0);
            return 0;
        }
        // permissionless: surplus routes to the configured harvester (which splits it
        // pro-rata), NEVER the caller. An earlier fallback paid `msg.sender` when the
        // harvester was unset — since `initialize` never assigns one, that made the
        // whole loop carry claimable by anyone in the deploy→wiring window. Fail
        // closed instead: no harvester, no harvest.
        if (harvester == address(0)) revert HarvesterUnset();
        pool.withdraw(address(prime), surplusPrime, address(this)); // HF stays ≥ target
        IERC20(address(prime)).safeTransfer(harvester, surplusPrime);
        emit Harvested(surplusPrime);
    }

    /// @inheritdoc ILeveragedLoop
    /// @dev Sizes the safety de-lever: sell collateral and repay loop debt with
    ///      the FULL proceeds (no payout) until HF is back at targetHf. With
    ///      hf = coll·lt/debt and proceeds x repaying debt 1:1,
    ///        (coll − x)·lt / (debt − x) = targetHf
    ///        ⇒ x = (targetHf·debt − lt·coll) / (targetHf − lt)
    ///      The spiral itself runs in pokeRepay (same machinery as unwind);
    ///      this only sets the repay target. Permissionless — HF-guarded, no
    ///      caller payout, repeated calls re-derive (not accumulate) the target.
    function deLever() external override nonReentrant {
        uint256 hf = healthFactor();
        if (hf > deLeverTrigger) revert HealthyEnough();
        (uint256 coll8, uint256 debt8, , uint256 ltBps, , ) = pool.getUserAccountData(address(this));
        uint256 ltWad = ltBps * 1e14; // bps → WAD
        // degenerate (no debt / LT ≥ target HF) or already at/above target
        if (debt8 == 0 || targetHf <= ltWad) revert HealthyEnough();
        if (hf >= targetHf) revert HealthyEnough();
        uint256 x8 = (targetHf * debt8 - ltWad * coll8) / (targetHf - ltWad);
        uint256 x18 = x8 * 1e10;
        if (x18 == 0 || x18 <= deleverDebtTarget) revert HealthyEnough();
        deleverDebtTarget = x18; // re-derive, don't accumulate
        emit DeLevered(hf, healthFactor());
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         VIEWS
    // ══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ILeveragedLoop
    function healthFactor() public view override returns (uint256) {
        (, , , , , uint256 hf) = pool.getUserAccountData(address(this));
        return hf;
    }

    /// @inheritdoc IYieldSource
    function totalEquity() public view override returns (uint256) {
        (uint256 collBase, uint256 debtBase, , , , ) = pool.getUserAccountData(address(this));
        return collBase > debtBase ? collBase - debtBase : 0;
    }

    /// @inheritdoc IYieldSource
    /// @dev The exact mirror of `harvest`: there, `reserved18 = principalEquity +
    ///      unwindTargetEquity` is the non-carry basis and surplus is
    ///      `equity18 - reserved18` when positive. Here we report the shortfall
    ///      `reserved18 - equity18` (when equity is below basis) as a fraction of
    ///      basis, in bps. Pure view — monitoring only, no state change.
    function negativeCarryBps() external view override returns (uint256) {
        uint256 reserved18 = principalEquity + unwindTargetEquity;
        if (reserved18 == 0) return 0;
        uint256 equity18 = totalEquity() * 1e10;
        if (equity18 >= reserved18) return 0;
        return ((reserved18 - equity18) * 1e4) / reserved18;
    }

    /// @inheritdoc IYieldSource
    function equityOf(address vault) external view override returns (uint256) {
        if (_totalShares == 0) return 0;
        return (totalEquity() * _sharesOf[vault]) / _totalShares;
    }

    /// @inheritdoc IYieldSource
    function sharesOf(address vault) external view override returns (uint256) {
        return _sharesOf[vault];
    }

    /// @inheritdoc IYieldSource
    function totalShares() external view override returns (uint256) {
        return _totalShares;
    }

    /// @inheritdoc IYieldSource
    function freedOf(address vault) external view override returns (uint256) {
        return freedHollar[vault];
    }

    /// @inheritdoc IYieldSource
    /// @dev `unwindRequested` is decremented on each `pullFreed`, so it is exactly
    ///      the still-owed in-flight amount (requested minus pulled) and is 0 once
    ///      the vault has pulled everything it asked to unwind.
    function pendingUnwindOf(address vault) external view override returns (uint256) {
        return unwindRequested[vault];
    }

    // ══════════════════════════════════════════════════════════════════════
    //                         ADMIN
    // ══════════════════════════════════════════════════════════════════════

    function registerVault(address vault) external onlyRole(ADMIN_ROLE) {
        _grantRole(VAULT_ROLE, vault);
    }

    function setTranches(uint256 _deployTranche, uint256 _unwindTranche) external onlyRole(ADMIN_ROLE) {
        deployTranche = _deployTranche;
        unwindTranche = _unwindTranche;
    }

    /// @notice Configure the HOLLAR↔aPRIME router route. Mainnet: 222/43/1043/143.
    function configureDca(
        uint32 _hollarAssetId,
        uint32 _primeAssetId,
        uint32 _aPrimeAssetId,
        uint32 _primePoolId,
        uint32 _slippagePpm
    ) external onlyRole(ADMIN_ROLE) {
        hollarAssetId = _hollarAssetId;
        primeAssetId = _primeAssetId;
        aPrimeAssetId = _aPrimeAssetId;
        primePoolId = _primePoolId;
        dcaSlippagePpm = _slippagePpm;
    }

    function setParams(
        uint256 _targetHf,
        uint256 _deployHfFloor,
        uint256 _deLeverTrigger,
        uint256 _harvestThreshold
    ) external onlyRole(ADMIN_ROLE) {
        targetHf = _targetHf;
        deployHfFloor = _deployHfFloor;
        deLeverTrigger = _deLeverTrigger;
        harvestThreshold = _harvestThreshold;
    }

    /// @notice Set the carry recipient. Cannot be zeroed: `harvest()` reverts while
    ///         unset, so re-zeroing would silently disable carry realisation for
    ///         every vault. Repoint to a new Harvester instead.
    function setHarvester(address _harvester) external onlyRole(ADMIN_ROLE) {
        if (_harvester == address(0)) revert ZeroAddress();
        harvester = _harvester;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[40] private __gap;
}
