// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MockERC20} from "./MockERC20.sol";
import {MockPool} from "./MockPool.sol";

/// @notice Test stand-in for the Frontier dispatch precompile (0x0401), where
///         `DcaDispatch.routerSell` sends its SCALE-encoded
///         `pallet_route::sell` calls. Tests `vm.etch` this contract's code at
///         the precompile address and `configure` it (storage lives at 0x0401).
///
///         It decodes the SCALE head (pallet, call, asset_in, asset_out,
///         amount_in, min_amount_out — the route tail is ignored; legs are
///         keyed by asset-id pair) and executes the swap with real-route
///         semantics against MockPool:
///
///         deploy  HOLLAR → aPRIME : burn caller HOLLAR, supply oracle-priced
///                                   PRIME on the caller's behalf (the folded
///                                   stableswap + Aave-supply hops);
///         unwind  aPRIME → HOLLAR : withdraw caller aPRIME (HF-checked, the
///                                   in-route Aave hop), mint oracle-priced
///                                   HOLLAR to the caller.
contract MockDispatch {
    uint8 internal constant ROUTER_PALLET = 67;
    uint8 internal constant SELL_CALL = 0;

    MockPool public pool;
    MockERC20 public hollar;
    MockERC20 public prime;
    uint32 public hollarId;
    uint32 public aPrimeId;
    /// @notice swap fee (bps) charged on the output of each leg — models the
    ///         stableswap fee / price impact of pool-143. 0 by default
    ///         (frictionless); must stay under the caller's slippage bound or
    ///         the minOut check rejects the fill (as it would live).
    uint16 public feeBps;

    function configure(
        address _pool,
        address _hollar,
        address _prime,
        uint32 _hollarId,
        uint32 _aPrimeId
    ) external {
        pool = MockPool(_pool);
        hollar = MockERC20(_hollar);
        prime = MockERC20(_prime);
        hollarId = _hollarId;
        aPrimeId = _aPrimeId;
    }

    function setFeeBps(uint16 _feeBps) external {
        feeBps = _feeBps;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length >= 42, "MockDispatch: short");
        require(uint8(input[0]) == ROUTER_PALLET && uint8(input[1]) == SELL_CALL, "MockDispatch: not router.sell");
        uint32 assetIn = _le32(input, 2);
        uint32 assetOut = _le32(input, 6);
        uint256 amountIn = _le128(input, 10);
        uint256 minOut = _le128(input, 26);

        (uint256 pHollar, ) = pool.assetPrice(address(hollar)); // 1e18 = $1
        (uint256 pPrime, ) = pool.assetPrice(address(prime));

        if (assetIn == hollarId && assetOut == aPrimeId) {
            // deploy leg: HOLLAR (18dp) → aPRIME (6dp) at the oracle rate
            hollar.burn(msg.sender, amountIn);
            uint256 out6 = (amountIn * pHollar) / pPrime / 1e12;
            out6 = (out6 * (10_000 - feeBps)) / 10_000;
            require(out6 >= minOut, "MockDispatch: minOut");
            prime.mint(address(this), out6);
            prime.approve(address(pool), out6);
            pool.supply(address(prime), out6, msg.sender, 0);
        } else if (assetIn == aPrimeId && assetOut == hollarId) {
            // unwind leg: aPRIME (6dp) → HOLLAR (18dp); the in-route withdraw
            // burns the caller's aPRIME and HF-checks the caller's position
            pool.mockWithdrawTo(address(prime), amountIn, msg.sender, address(this));
            prime.burn(address(this), amountIn);
            uint256 out18 = (amountIn * pPrime * 1e12) / pHollar;
            out18 = (out18 * (10_000 - feeBps)) / 10_000;
            require(out18 >= minOut, "MockDispatch: minOut");
            hollar.mint(msg.sender, out18);
        } else {
            revert("MockDispatch: unknown pair");
        }
        return "";
    }

    function _le32(bytes calldata b, uint256 o) internal pure returns (uint32 x) {
        x = uint32(uint8(b[o])) | (uint32(uint8(b[o + 1])) << 8) | (uint32(uint8(b[o + 2])) << 16)
            | (uint32(uint8(b[o + 3])) << 24);
    }

    function _le128(bytes calldata b, uint256 o) internal pure returns (uint256 x) {
        for (uint256 i = 0; i < 16; i++) {
            x |= uint256(uint8(b[o + i])) << (8 * i);
        }
    }
}
