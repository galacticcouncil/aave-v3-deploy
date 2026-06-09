// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

/// @notice Deploy a second Propeller CollateralVault for tBTC, wired to the LIVE
///         lark-2 deployment (shared SubLoop, shared SyntheticToken, main-market
///         pool). New proxy points at the existing keeperless Vault impl; only a
///         fresh proxy + initialize is needed — the impl, SubLoop, synth, and
///         tBTC/HOLLAR/synth reserves all already exist.
///
///         Post-deploy governance (separate referendum): SubLoop.registerVault,
///         Harvester.addVault, synth.grantRole(MINTER, vault).
///
///         forge script script/DeployVaultTBTC.s.sol:DeployVaultTBTC \
///           --rpc-url https://2.lark.hydration.cloud --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeployVaultTBTC is Script {
    // live lark-2 deployment
    address constant IMPL = 0x880d1234773Cf680D2114155a634Fa5253576aC3; // keeperless CollateralVault impl
    address constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38; // main market
    address constant SUBLOOP = 0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8;
    address constant SYNTH = 0x23B69fd91a463ECB4B5864e4C2Ec6a20AFEC47b8; // shared synthetic
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant HOLLAR_VDEBT = 0x342923782cCaEBf9c38DD9cb40436e82C42c73B5; // main-market HOLLAR variable debt
    address constant SWAPPER = 0xAa7e0000000000000000000000000000000Aa7e0; // placeholder (same as ETH vault)
    address constant GOV = 0xAa7e0000000000000000000000000000000Aa7e0;

    // tBTC (substrate asset 1000765)
    address constant TBTC = 0x00000000000000000000000000000001000f453d;
    address constant ATBTC = 0x69003a65189f6Ed993D3bD3E2B74f1Db39F405ce;

    uint16 constant SYNTH_LT_BPS = 9800;
    uint256 constant TVL_CAP = 50e18; // aligns with tBTC supply cap

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes memory init = abi.encodeCall(
            CollateralVault.initialize,
            (
                "Propeller tBTC",
                "ptBTC",
                TBTC,
                POOL,
                SUBLOOP,
                SWAPPER,
                HOLLAR,
                SYNTH,
                ATBTC,
                HOLLAR_VDEBT,
                SYNTH_LT_BPS,
                TVL_CAP,
                GOV
            )
        );
        vm.startBroadcast(deployerKey);
        ERC1967Proxy proxy = new ERC1967Proxy(IMPL, init);
        vm.stopBroadcast();
        console2.log("tBTC CollateralVault (proxy):", address(proxy));
    }
}
