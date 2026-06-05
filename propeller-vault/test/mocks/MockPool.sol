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

    // ── value helpers (native units → 8-dp USD) ───────────────────────────
    function _usd8(address asset, uint256 amt) internal view returns (uint256) {
        Reserve storage r = reserves[asset];
        // amt(native) * price(1e18=$1) / 10^dec → 18dp USD; / 1e10 → 8dp USD
        return (amt * r.priceWad) / (10 ** r.decimals) / 1e10;
    }

    // ── IAavePool ─────────────────────────────────────────────────────────
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        reserves[asset].aToken.mint(onBehalfOf, amount);
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

    function setUserUseReserveAsCollateral(address, bool) external override {}

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

    function getReserveData(address) external pure override returns (bytes memory) {
        return "";
    }

    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external pure override {
        revert("MockPool: flash unused");
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
            if (c > 0) {
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
