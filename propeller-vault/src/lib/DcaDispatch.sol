// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title DcaDispatch
/// @notice SCALE-encodes `pallet_dca::schedule(Schedule, Option<start_block>)` and
///         dispatches it through the Frontier **dispatch precompile (0x0401)**.
///         Because the calling contract invokes 0x0401 *itself*, the Substrate
///         origin is that contract's mapped account — so the DCA order is owned
///         by the caller (the SubLoop), which is required (the order trades on
///         the caller's own Aave position).
///
/// @dev    SWAP SEAM: this is the "now" implementation of `IDcaScheduler`-shaped
///         scheduling. A future, gas-optimized path is a dedicated **DCA
///         precompile** with a typed ABI (same origin semantics) — drop it in
///         behind the same seam (see SubLoop: if `dca != address(0)` it calls
///         that precompile; else it uses this library inline). Keeping the
///         encoding in a *library* (not a contract) means it runs in the
///         caller's context, preserving the origin.
///
///         ⚠️ The pallet/call indices and type layout are pinned constants
///         verified against mainnet runtime metadata (polkadot.js) — see
///         test/DcaDispatch.t.sol, which asserts byte-equality with the
///         reference encoding. Re-run that test after any runtime upgrade;
///         a reordered pallet set silently changes these bytes.
library DcaDispatch {
    address internal constant DISPATCH = 0x0000000000000000000000000000000000000401;

    uint8 internal constant DCA_PALLET = 66; // construct_runtime: DCA = 66
    uint8 internal constant SCHEDULE_CALL = 0; // pallet_dca::Call::schedule is call 0
    uint8 internal constant ROUTER_PALLET = 67; // construct_runtime: Router = 67
    uint8 internal constant SELL_CALL = 0; // pallet_route::Call::sell is call 0

    // PoolType<AssetId> SCALE tags (traits/src/router.rs)
    uint8 internal constant POOL_XYK = 0;
    uint8 internal constant POOL_LBP = 1;
    uint8 internal constant POOL_STABLESWAP = 2; // + AssetId(u32) poolId
    uint8 internal constant POOL_OMNIPOOL = 3;
    uint8 internal constant POOL_AAVE = 4;

    /// @dev One router hop. `poolArg` used only for Stableswap (the pool id).
    struct Hop {
        uint8 poolTag;
        bool hasArg;
        uint32 poolArg;
        uint32 assetIn;
        uint32 assetOut;
    }

    error DispatchFailed();

    // ── public API ────────────────────────────────────────────────────────

    /// @notice Encode a `schedule` with a `Sell` order. max_retries/stability =
    ///         None, slippage = Some(slippagePpm), start_execution_block = None.
    function encodeScheduleSell(
        bytes32 owner,
        uint32 period,
        uint128 totalAmount,
        uint32 slippagePpm,
        uint32 assetIn,
        uint32 assetOut,
        uint128 amountIn,
        uint128 minAmountOut,
        Hop[] memory route
    ) internal pure returns (bytes memory) {
        bytes memory head = abi.encodePacked(
            DCA_PALLET,
            SCHEDULE_CALL,
            owner, // AccountId32
            _le32(period), // BlockNumber
            _le128(totalAmount), // Balance
            bytes1(0x00), // max_retries: Option<u8> = None
            bytes1(0x00), // stability_threshold: Option<Permill> = None
            bytes1(0x01),
            _le32(slippagePpm), // slippage: Option<Permill> = Some(ppm)
            bytes1(0x00), // Order tag: Sell = 0
            _le32(assetIn),
            _le32(assetOut),
            _le128(amountIn),
            _le128(minAmountOut)
        );
        // route: BoundedVec<Trade> → compact(len) ++ each Trade
        bytes memory r = _compact(uint32(route.length));
        for (uint256 i = 0; i < route.length; i++) {
            r = abi.encodePacked(r, _encodeTrade(route[i]));
        }
        // start_execution_block: Option<BlockNumber> = None
        return abi.encodePacked(head, r, bytes1(0x00));
    }

    /// @notice Encode + dispatch via 0x0401 (origin = this caller's account).
    function scheduleSell(
        uint32 period,
        uint128 totalAmount,
        uint32 slippagePpm,
        uint32 assetIn,
        uint32 assetOut,
        uint128 amountIn,
        uint128 minAmountOut,
        Hop[] memory route
    ) internal {
        bytes memory call = encodeScheduleSell(
            ownerOf(address(this)), period, totalAmount, slippagePpm,
            assetIn, assetOut, amountIn, minAmountOut, route
        );
        (bool ok, ) = DISPATCH.call(call);
        if (!ok) revert DispatchFailed();
    }

    /// @notice Encode + dispatch `pallet_route::sell(asset_in, asset_out, amount_in,
    ///         min_amount_out, route)` via 0x0401 (origin = this caller's account).
    ///         Synchronous swap that executes through the route's pools with a
    ///         caller-set min-out — it does NOT do pallet-DCA's EMA-oracle budget
    ///         valuation, so it can sell assets the oracle can't price (e.g. the
    ///         aToken aPRIME, which trades in no pool). Used by the unwind spiral.
    function routerSell(
        uint32 assetIn,
        uint32 assetOut,
        uint128 amountIn,
        uint128 minAmountOut,
        Hop[] memory route
    ) internal {
        bytes memory head = abi.encodePacked(
            ROUTER_PALLET, SELL_CALL,
            _le32(assetIn), _le32(assetOut), _le128(amountIn), _le128(minAmountOut)
        );
        bytes memory r = _compact(uint32(route.length));
        for (uint256 i = 0; i < route.length; i++) {
            r = abi.encodePacked(r, _encodeTrade(route[i]));
        }
        (bool ok, ) = DISPATCH.call(abi.encodePacked(head, r));
        if (!ok) revert DispatchFailed();
    }

    /// @notice EVM-derived Substrate AccountId32 for an address:
    ///         [20-byte addr][b"ETH\0"][8x00] (pallet-evm-accounts mapping).
    function ownerOf(address a) internal pure returns (bytes32) {
        // Hydration truncated AccountId: b"ETH\0" ++ 20-byte addr ++ 8x00
        // (pallet-evm-accounts truncated_account_id; prefix is FIRST).
        return bytes32(abi.encodePacked(bytes4(0x45544800), a, bytes8(0)));
    }

    // ── SCALE helpers ─────────────────────────────────────────────────────

    function _encodeTrade(Hop memory h) private pure returns (bytes memory) {
        bytes memory pool = h.hasArg
            ? abi.encodePacked(h.poolTag, _le32(h.poolArg))
            : abi.encodePacked(h.poolTag);
        return abi.encodePacked(pool, _le32(h.assetIn), _le32(h.assetOut));
    }

    function _le32(uint32 x) private pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(uint8(x)), bytes1(uint8(x >> 8)), bytes1(uint8(x >> 16)), bytes1(uint8(x >> 24))
        );
    }

    function _le128(uint128 x) private pure returns (bytes memory b) {
        b = new bytes(16);
        for (uint256 i = 0; i < 16; i++) {
            b[i] = bytes1(uint8(x >> (8 * i)));
        }
    }

    /// @dev SCALE compact-u32 (covers all 4 modes; route lengths use 1-byte mode).
    function _compact(uint32 x) private pure returns (bytes memory) {
        if (x < 64) {
            return abi.encodePacked(bytes1(uint8(x) << 2)); // mode 0b00
        } else if (x < 16384) {
            uint16 v = (uint16(x) << 2) | 0x01; // mode 0b01
            return abi.encodePacked(bytes1(uint8(v)), bytes1(uint8(v >> 8)));
        } else if (x < 1073741824) {
            uint32 v = (x << 2) | 0x02; // mode 0b10
            return _le32(v);
        } else {
            return abi.encodePacked(bytes1(0x03), _le32(x)); // mode 0b11, 4-byte
        }
    }
}
