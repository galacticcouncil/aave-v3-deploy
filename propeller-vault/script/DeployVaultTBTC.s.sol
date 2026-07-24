// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

/// @notice Deploy a second Propeller CollateralVault for tBTC, wired to an
///         EXISTING deployment (shared SubLoop, shared SyntheticToken, main-market
///         pool + the already-deployed Vault impl). Only a fresh proxy +
///         initialize is needed.
///
///         Post-deploy governance (separate referendum): SubLoop.registerVault,
///         Harvester.addVault, synth.grantRole(MINTER, vault).
///
///         All addresses read via `vm.envOr`, defaulting to the LIVE lark-2
///         deployment — so lark-2 needs no env; lark-4 supplies a `.env`.
///         Required: PRIVATE_KEY. Optional overrides (else lark-2 default): IMPL,
///         POOL, SUBLOOP, SYNTH, HOLLAR, HOLLAR_VDEBT, SWAPPER, GOV, TBTC, ATBTC,
///         SYNTH_LT_BPS, TVL_CAP.
///
///         forge script script/DeployVaultTBTC.s.sol:DeployVaultTBTC \
///           --rpc-url $RPC --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeployVaultTBTC is Script {
    // live lark-2 defaults
    address constant D_IMPL = 0x880d1234773Cf680D2114155a634Fa5253576aC3; // CollateralVault impl
    address constant D_POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38; // main market
    address constant D_SUBLOOP = 0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8;
    address constant D_SYNTH = 0x23B69fd91a463ECB4B5864e4C2Ec6a20AFEC47b8; // shared synthetic
    address constant D_HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant D_HOLLAR_VDEBT = 0x342923782cCaEBf9c38DD9cb40436e82C42c73B5; // main-market HOLLAR variable debt
    address constant D_SWAPPER = 0xAa7e0000000000000000000000000000000Aa7e0; // placeholder (same as ETH vault)
    address constant D_GOV = 0xAa7e0000000000000000000000000000000Aa7e0;
    address constant D_TBTC = 0x00000000000000000000000000000001000f453d; // substrate asset 1000765
    address constant D_ATBTC = 0x69003a65189f6Ed993D3bD3E2B74f1Db39F405ce;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address impl = vm.envOr("IMPL", D_IMPL);
        address pool = vm.envOr("POOL", D_POOL);
        address subLoop = vm.envOr("SUBLOOP", D_SUBLOOP);
        address synth = vm.envOr("SYNTH", D_SYNTH);
        address hollar = vm.envOr("HOLLAR", D_HOLLAR);
        address hollarVDebt = vm.envOr("HOLLAR_VDEBT", D_HOLLAR_VDEBT);
        address swapper = vm.envOr("SWAPPER", D_SWAPPER);
        address gov = vm.envOr("GOV", D_GOV);
        address tbtc = vm.envOr("TBTC", D_TBTC);
        address aTbtc = vm.envOr("ATBTC", D_ATBTC);
        uint16 synthLtBps = uint16(vm.envOr("SYNTH_LT_BPS", uint256(9800)));
        uint256 tvlCap = vm.envOr("TVL_CAP", uint256(50e18)); // aligns with tBTC supply cap

        bytes memory init = abi.encodeCall(
            CollateralVault.initialize,
            (
                "Propeller tBTC",
                "ptBTC",
                tbtc,
                pool,
                subLoop,
                swapper,
                hollar,
                synth,
                aTbtc,
                hollarVDebt,
                synthLtBps,
                tvlCap,
                gov
            )
        );
        vm.startBroadcast(deployerKey);
        ERC1967Proxy proxy = new ERC1967Proxy(impl, init);
        vm.stopBroadcast();
        console2.log("tBTC CollateralVault (proxy):", address(proxy));
    }
}
