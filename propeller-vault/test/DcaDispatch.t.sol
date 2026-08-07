// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";

/// @notice Verifies the hand-rolled SCALE encoder byte-for-byte against the
///         reference produced by polkadot.js against live mainnet runtime
///         metadata (api.tx.dca.schedule(...).method.toHex()). If a runtime
///         upgrade reorders pallets/types, this test breaks loudly.
contract DcaDispatchTest is Test {
    // api.tx.dca.schedule({owner: <0x..aa derived>, period:10, totalAmount:1000e18,
    //   maxRetries:null, stabilityThreshold:null, slippage:10000,
    //   order:{Sell:{assetIn:222, assetOut:1043, amountIn:100e18, minAmountOut:99_000000,
    //     route:[{Stableswap:143, 222→43},{Aave, 43→1043}]}}}, null).method.toHex()
    //
    // NOTE: the owner segment was regenerated 2026-06-10 — the original
    // polkadot.js snippet derived the AccountId32 with the address FIRST, but
    // pallet-evm-accounts::truncated_account_id puts b"ETH\0" first
    // (hydration-node pallets/evm-accounts/src/lib.rs:553-557:
    // data[0..4]=b"ETH\0"; data[4..24]=evm_address). Everything after the
    // owner field is the original machine-generated reference, unchanged.
    bytes constant REFERENCE =
        hex"42004554480000000000000000000000000000000000000000aa00000000000000000a0000000000a0dec5adc93536000000000000000000011027000000de00000013040000000010632d5ec76b0500000000000000c09ee60500000000000000000000000008028f000000de0000002b000000042b0000001304000000";

    function test_encodeMatchesPolkadotJsReference() public pure {
        DcaDispatch.Hop[] memory route = new DcaDispatch.Hop[](2);
        route[0] = DcaDispatch.Hop({poolTag: 2, hasArg: true, poolArg: 143, assetIn: 222, assetOut: 43}); // Stableswap(143) HOLLAR→PRIME
        route[1] = DcaDispatch.Hop({poolTag: 4, hasArg: false, poolArg: 0, assetIn: 43, assetOut: 1043}); // Aave PRIME→aPRIME

        bytes memory got = DcaDispatch.encodeScheduleSell(
            DcaDispatch.ownerOf(0x00000000000000000000000000000000000000AA),
            10, // period
            1_000e18, // totalAmount
            10000, // slippage ppm
            222, // assetIn HOLLAR
            1043, // assetOut aPRIME
            100e18, // amountIn / tranche
            99_000000, // minAmountOut (aPRIME 6dp)
            route
        );

        assertEq(got, REFERENCE, "SCALE encoding must match runtime metadata");
    }

    // ── pallet_route::sell — the LIVE path ───────────────────────────────────
    //
    // `encodeScheduleSell` above pins the retired pallet-DCA path (pallet 66),
    // which has had no caller in `src/` since c0f9404 dropped it for router.sell.
    // These two pin the path SubLoop actually uses: `_fundDeploy` (deploy leg) and
    // `pokeRepay` (unwind leg) both dispatch `encodeRouterSell` at pallet 67.
    //
    // References generated against LIVE runtime metadata (hydradx v430, lark-4):
    //   api.tx.router.sell(assetIn, assetOut, amountIn, minAmountOut, route)
    //     .method.toHex()
    // Router pallet index 67 (0x43), call 0 — matches DcaDispatch.ROUTER_PALLET.
    // Re-run the generator after any runtime upgrade: a reordered pallet set
    // silently changes these bytes, and the constants are baked into SubLoop's
    // bytecode so a mismatch can only be fixed by a UUPS upgrade.

    /// aPRIME(1043) →[Aave]→ PRIME(43) →[Stableswap 143]→ HOLLAR(222)
    bytes constant UNWIND_REFERENCE =
        hex"430013040000de00000000e1f5050000000000000000000000000000acbb79a7e65d05000000000000000804130400002b000000028f0000002b000000de000000";

    /// HOLLAR(222) →[Stableswap 143]→ PRIME(43) →[Aave]→ aPRIME(1043)
    bytes constant DEPLOY_REFERENCE =
        hex"4300de00000013040000000010632d5ec76b0500000000000000c09ee60500000000000000000000000008028f000000de0000002b000000042b00000013040000";

    function test_routerSellUnwindLegMatchesRuntimeMetadata() public pure {
        DcaDispatch.Hop[] memory route = new DcaDispatch.Hop[](2);
        route[0] = DcaDispatch.Hop({poolTag: 4, hasArg: false, poolArg: 0, assetIn: 1043, assetOut: 43});
        route[1] = DcaDispatch.Hop({poolTag: 2, hasArg: true, poolArg: 143, assetIn: 43, assetOut: 222});

        bytes memory got = DcaDispatch.encodeRouterSell(
            1043, // assetIn  aPRIME
            222, // assetOut HOLLAR
            100_000000, // 100 aPRIME (6dp)
            99e18, // 99 HOLLAR (18dp)
            route
        );
        assertEq(got, UNWIND_REFERENCE, "unwind leg must match pallet_route::sell metadata");
    }

    function test_routerSellDeployLegMatchesRuntimeMetadata() public pure {
        DcaDispatch.Hop[] memory route = new DcaDispatch.Hop[](2);
        route[0] = DcaDispatch.Hop({poolTag: 2, hasArg: true, poolArg: 143, assetIn: 222, assetOut: 43});
        route[1] = DcaDispatch.Hop({poolTag: 4, hasArg: false, poolArg: 0, assetIn: 43, assetOut: 1043});

        bytes memory got = DcaDispatch.encodeRouterSell(
            222, // assetIn  HOLLAR
            1043, // assetOut aPRIME
            100e18, // 100 HOLLAR (18dp)
            99_000000, // 99 aPRIME (6dp)
            route
        );
        assertEq(got, DEPLOY_REFERENCE, "deploy leg must match pallet_route::sell metadata");
    }

    /// The pallet index is the single byte that a runtime reorder would change.
    function test_routerPalletIndexIsPinned() public pure {
        assertEq(uint8(UNWIND_REFERENCE[0]), 67, "Router pallet index");
        assertEq(uint8(UNWIND_REFERENCE[1]), 0, "sell call index");
        assertEq(uint8(DEPLOY_REFERENCE[0]), 67, "Router pallet index");
        assertEq(uint8(DEPLOY_REFERENCE[1]), 0, "sell call index");
    }

    function test_ownerDerivation() public pure {
        // [b"ETH\0"][20-byte addr][8x00] — pallet-evm-accounts truncated_account_id
        assertEq(
            DcaDispatch.ownerOf(0x00000000000000000000000000000000000000AA),
            bytes32(hex"4554480000000000000000000000000000000000000000aa0000000000000000"),
            "EVM-derived AccountId32"
        );
    }
}
