// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Harvester} from "../src/Harvester.sol";

/// @notice Deploy the Propeller stack (SubLoop + ETH CollateralVault + Harvester)
///         against a mainnet-mirrored money market: ETH collateral + HOLLAR debt
///         + synthetic floor; PRIME the value-stable loop asset. admin =
///         governance aave-manager.
///
///         Every chain-specific address and risk param is read via `vm.envOr`,
///         defaulting to the **lark-2** values — so a lark-2 deploy needs no env,
///         and lark-4 (or mainnet) just supplies a `.env`. Required: PRIVATE_KEY,
///         SYNTH (address of the SyntheticToken from DeploySynth). Optional
///         overrides (else lark-2 default): POOL, HOLLAR, HOLLAR_VDEBT, ETH, AETH,
///         PRIME, APRIME, GOV, SWAPPER, TARGET_HF, DELEVER_TRIGGER, SYNTH_LT_BPS,
///         TVL_CAP.
///
///         forge script script/DeployMain.s.sol:DeployMain \
///           --rpc-url $RPC --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeployMain is Script {
    // lark-2 defaults (overridable per-chain via env)
    address constant D_POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address constant D_HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant D_HOLLAR_VDEBT = 0x342923782cCaEBf9c38DD9cb40436e82C42c73B5;
    address constant D_ETH = 0x0000000000000000000000000000000100000022; // collateral, 18dp
    address constant D_AETH = 0x11a8f7fFbB7e0fbEd88BC20179Dd45B4Bd6874ff;
    address constant D_PRIME = 0x000000000000000000000000000000010000002B; // loop asset, 6dp
    address constant D_APRIME = 0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7;
    address constant D_GOV = 0xAa7e0000000000000000000000000000000Aa7e0;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address synth = vm.envAddress("SYNTH");

        address pool = vm.envOr("POOL", D_POOL);
        address hollar = vm.envOr("HOLLAR", D_HOLLAR);
        address hollarVDebt = vm.envOr("HOLLAR_VDEBT", D_HOLLAR_VDEBT);
        address eth = vm.envOr("ETH", D_ETH);
        address aEth = vm.envOr("AETH", D_AETH);
        address prime = vm.envOr("PRIME", D_PRIME);
        address aPrime = vm.envOr("APRIME", D_APRIME);
        address gov = vm.envOr("GOV", D_GOV);
        // swapper (HydraAugustus). Defaults to GOV as a placeholder until REQ-SWAP
        // is deployed; pass the real HydraAugustus address on lark-4. Repointable
        // later via CollateralVault.setSwapper without redeploy.
        address swapper = vm.envOr("SWAPPER", gov);

        uint256 targetHf = vm.envOr("TARGET_HF", uint256(1.05e18));
        uint256 deLeverTrigger = vm.envOr("DELEVER_TRIGGER", uint256(1.10e18));
        uint16 synthLtBps = uint16(vm.envOr("SYNTH_LT_BPS", uint256(9800)));
        uint256 tvlCap = vm.envOr("TVL_CAP", uint256(1_000_000e18));

        vm.startBroadcast(deployerKey);

        SubLoop loopImpl = new SubLoop();
        bytes memory loopInit = abi.encodeCall(
            SubLoop.initialize, (pool, hollar, prime, aPrime, targetHf, deLeverTrigger, gov)
        );
        SubLoop subLoop = SubLoop(address(new ERC1967Proxy(address(loopImpl), loopInit)));

        CollateralVault vaultImpl = new CollateralVault();
        bytes memory vaultInit = abi.encodeCall(
            CollateralVault.initialize,
            (
                "Propeller ETH",
                "pETH",
                eth,
                pool,
                address(subLoop),
                swapper,
                hollar,
                synth,
                aEth,
                hollarVDebt,
                synthLtBps,
                tvlCap,
                gov
            )
        );
        CollateralVault vault = CollateralVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        Harvester harvester = new Harvester(address(subLoop), prime, gov);

        vm.stopBroadcast();

        console.log("SubLoop (proxy):", address(subLoop));
        console.log("CollateralVault (proxy):", address(vault));
        console.log("Harvester:", address(harvester));
        console.log("synth:", synth);
        console.log("swapper:", swapper);
    }
}
