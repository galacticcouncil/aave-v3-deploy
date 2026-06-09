// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal Aave v3 Pool mock that follows real getUserAccountData
///         conventions: base values in 8-dp USD, liquidation threshold / LTV in
///         bps, health factor in WAD (1e18). So the contract math under test is
///         written to real Aave semantics, not mock-isms.
///
/// @dev    Tracks collateral via per-reserve aToken balances and debt via
///         per-reserve variable-debt-token balances (both MockERC20s minted by
///         this pool). `borrow` mints the borrowed asset to the caller (GHO/
///         HOLLAR-style). HF is enforced on borrow/withdraw.
contract MockPool is IAavePool {
    struct Reserve {
        MockERC20 aToken;
        MockERC20 debtToken;
        uint16 ltBps; // liquidation threshold
        uint16 ltvBps; // loan-to-value (borrow power)
        uint8 decimals;
        uint256 priceWad; // 1e18 = $1
        bool exists;
    }

    mapping(address => Reserve) public reserves;
    address[] public assets;
    /// @notice user => asset => counts as collateral. Models Aave's
    ///         use-as-collateral flag: auto-set only on the FIRST supply and
    ///         only when the reserve LTV > 0 (ValidationLogic LTV==0 gate) —
    ///         the exact semantics that made the LTV-0 synth floor inert on
    ///         the live market (bug B). An un-flagged aToken balance is NOT in
    ///         totalCollateralBase.
    mapping(address => mapping(address => bool)) public usingAsCollateral;

    uint256 internal constant BPS = 1e4;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HF_MAX = type(uint256).max;

    function initReserve(
        address asset,
        address aToken,
        address debtToken,
        uint16 ltBps,
        uint16 ltvBps,
        uint8 dec,
        uint256 priceWad
    ) external {
        reserves[asset] = Reserve(MockERC20(aToken), MockERC20(debtToken), ltBps, ltvBps, dec, priceWad, true);
        assets.push(asset);
    }

    function setPrice(address asset, uint256 priceWad) external {
        reserves[asset].priceWad = priceWad;
    }

    /// @notice Test helper: governance changing a reserve's max LTV (does NOT
    ///         retro-enable existing suppliers — matches Aave).
    function setLtv(address asset, uint16 ltvBps) external {
        reserves[asset].ltvBps = ltvBps;
    }

    /// @notice Price ($1 = 1e18) and decimals for a reserve — used by MockSwapper
    ///         to price cross-asset swaps the way an oracle-fed router would.
    function assetPrice(address asset) external view returns (uint256 priceWad, uint8 dec) {
        Reserve storage r = reserves[asset];
        return (r.priceWad, r.decimals);
    }

    // ── value helpers (native units → 8-dp USD) ───────────────────────────
    function _usd8(address asset, uint256 amt) internal view returns (uint256) {
        Reserve storage r = reserves[asset];
        // amt(native) * price(1e18=$1) / 10^dec → 18dp USD; / 1e10 → 8dp USD
        return (amt * r.priceWad) / (10 ** r.decimals) / 1e10;
    }

    // ── IAavePool ─────────────────────────────────────────────────────────
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        Reserve storage r = reserves[asset];
        bool firstSupply = r.aToken.balanceOf(onBehalfOf) == 0;
        r.aToken.mint(onBehalfOf, amount);
        // Aave SupplyLogic.executeSupply: auto-enable only on first supply,
        // and validateAutomaticUseAsCollateral rejects LTV-0 reserves.
        if (firstSupply && r.ltvBps > 0) usingAsCollateral[onBehalfOf][asset] = true;
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        reserves[asset].aToken.burn(msg.sender, amount);
        require(_hf(msg.sender) >= WAD, "MockPool: HF<1 after withdraw");
        // pool must hold the asset (was supplied here); send it out
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        reserves[asset].debtToken.mint(onBehalfOf, amount);
        MockERC20(asset).mint(msg.sender, amount); // GHO/HOLLAR-style: minted on borrow
        require(_hf(onBehalfOf) >= WAD, "MockPool: HF<1 after borrow");
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf)
        external
        override
        returns (uint256)
    {
        uint256 d = reserves[asset].debtToken.balanceOf(onBehalfOf);
        uint256 r = amount > d ? d : amount;
        IERC20(asset).transferFrom(msg.sender, address(this), r);
        reserves[asset].debtToken.burn(onBehalfOf, r);
        return r;
    }

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external override {
        Reserve storage r = reserves[asset];
        if (useAsCollateral) {
            // Aave: UNDERLYING_BALANCE_ZERO + USER_IN_ISOLATION_MODE_OR_LTV_ZERO
            require(r.aToken.balanceOf(msg.sender) > 0, "MockPool: balance 0");
            require(r.ltvBps > 0, "MockPool: ltv 0");
            usingAsCollateral[msg.sender][asset] = true;
        } else {
            usingAsCollateral[msg.sender][asset] = false;
            require(_hf(msg.sender) >= WAD, "MockPool: HF<1 after disable");
        }
    }

    /// @notice Aave reserve configuration bitmap: bits 0-15 LTV, 16-31 LT.
    function getConfiguration(address asset) external view returns (uint256) {
        Reserve storage r = reserves[asset];
        return uint256(r.ltvBps) | (uint256(r.ltBps) << 16);
    }

    /// @notice Mock of the router/AaveTradeExecutor's on-behalf withdraw (the
    ///         first hop of an unwind DCA route): burn `from`'s aToken and send
    ///         the underlying to `to`. HF on `from` must stay >= 1.
    function mockWithdrawTo(address asset, uint256 amount, address from, address to)
        external
        returns (uint256)
    {
        reserves[asset].aToken.burn(from, amount);
        require(_hf(from) >= WAD, "MockPool: HF<1 after withdraw");
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    /// @notice aToken amount of `asset` that `user` can withdraw while keeping
    ///         HF >= 1.01 (a small buffer above liquidation). Used by the unwind
    ///         DCA to size each tranche within the HF-safe sliver.
    function maxWithdrawable(address user, address asset) external view returns (uint256) {
        Reserve storage r = reserves[asset];
        uint256 bal = r.aToken.balanceOf(user);
        (, uint256 collWithLt8, uint256 debt8,) = _account(user);
        if (debt8 == 0) return bal;
        uint256 needed = (debt8 * 101) / 100; // HF >= 1.01
        if (collWithLt8 <= needed) return 0;
        uint256 vFree8 = ((collWithLt8 - needed) * BPS) / r.ltBps; // base8 value
        uint256 amt = (vFree8 * 1e10 * (10 ** r.decimals)) / r.priceWad; // → native
        return amt > bal ? bal : amt;
    }

    function getUserAccountData(address user)
        external
        view
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        (uint256 collBase8, uint256 collWithLt8, uint256 debtBase8, uint256 wAvgLtBps) = _account(user);
        uint256 hf = debtBase8 == 0 ? HF_MAX : (collWithLt8 * WAD) / debtBase8;
        // availableBorrowsBase: simplistic LTV-based headroom (not exercised in deploy test)
        return (collBase8, debtBase8, 0, wAvgLtBps, 0, hf);
    }

    // Doubles as its own PoolAddressesProvider + AaveOracle so oracle-based
    // min-out sizing resolves in tests. Returns each asset's real USD price (8dp)
    // from its reserve `priceWad` (1e18 = $1) — consistent with MockSwapper's
    // pricing, so the vault's compound oracle-floor matches the swap output.
    // HOLLAR/PRIME stay $1 → SubLoop's 1:1 min-out math is unchanged.
    function ADDRESSES_PROVIDER() external view returns (address) { return address(this); }
    function getPriceOracle() external view returns (address) { return address(this); }
    function getAssetPrice(address asset) external view returns (uint256) {
        return reserves[asset].priceWad / 1e10; // 1e18 $1 → 1e8 (8dp USD)
    }

    function _hf(address user) internal view returns (uint256) {
        (, uint256 collWithLt8, uint256 debtBase8,) = _account(user);
        return debtBase8 == 0 ? HF_MAX : (collWithLt8 * WAD) / debtBase8;
    }

    function _account(address user)
        internal
        view
        returns (uint256 collBase8, uint256 collWithLt8, uint256 debtBase8, uint256 wAvgLtBps)
    {
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; i++) {
            Reserve storage r = reserves[assets[i]];
            uint256 c = r.aToken.balanceOf(user);
            // only FLAGGED balances count — an aToken supplied while the
            // reserve was LTV-0 is invisible to HF/collateral (matches Aave).
            if (c > 0 && usingAsCollateral[user][assets[i]]) {
                uint256 v = _usd8(assets[i], c);
                collBase8 += v;
                collWithLt8 += (v * r.ltBps) / BPS;
            }
            uint256 d = r.debtToken.balanceOf(user);
            if (d > 0) debtBase8 += _usd8(assets[i], d);
        }
        wAvgLtBps = collBase8 == 0 ? 0 : (collWithLt8 * BPS) / collBase8;
    }
}
