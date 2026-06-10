// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Harvester} from "../src/Harvester.sol";

/// @notice Deploy the Propeller stack against the lark2 MAIN money market
///         (pool 0x1b02E051…, the mainnet-mirrored instance with real ETH / PRIME
///         / HOLLAR + stableswap pool-143 HOLLAR↔PRIME). The faithful design:
///         ETH collateral + HOLLAR debt + synthetic floor; PRIME the value-stable
///         loop asset. admin = governance aave-manager.
///
///         forge script script/DeployMain.s.sol:DeployMain \
///           --rpc-url https://2.lark.hydration.cloud --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeployMain is Script {
    address constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant HOLLAR_VDEBT = 0x342923782cCaEBf9c38DD9cb40436e82C42c73B5;
    address constant ETH = 0x0000000000000000000000000000000100000022; // collateral, 18dp
    address constant AETH = 0x11a8f7fFbB7e0fbEd88BC20179Dd45B4Bd6874ff;
    address constant PRIME = 0x000000000000000000000000000000010000002B; // loop asset, 6dp
    address constant APRIME = 0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7;
    address constant GOV = 0xAa7e0000000000000000000000000000000Aa7e0;

    uint256 constant TARGET_HF = 1.05e18;
    uint256 constant DELEVER_TRIGGER = 1.10e18;
    uint16 constant SYNTH_LT_BPS = 9800;
    uint256 constant TVL_CAP = 1_000_000e18;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address synth = vm.envAddress("SYNTH");

        vm.startBroadcast(deployerKey);

        SubLoop loopImpl = new SubLoop();
        bytes memory loopInit = abi.encodeCall(
            SubLoop.initialize,
            (POOL, HOLLAR, PRIME, APRIME, TARGET_HF, DELEVER_TRIGGER, GOV)
        );
        SubLoop subLoop = SubLoop(address(new ERC1967Proxy(address(loopImpl), loopInit)));

        CollateralVault vaultImpl = new CollateralVault();
        bytes memory vaultInit = abi.encodeCall(
            CollateralVault.initialize,
            (
                "Propeller ETH",
                "pETH",
                ETH,
                POOL,
                address(subLoop),
                GOV, // swapper placeholder (REQ-SWAP not yet deployed)
                HOLLAR,
                synth,
                AETH,
                HOLLAR_VDEBT,
                SYNTH_LT_BPS,
                TVL_CAP,
                GOV
            )
        );
        CollateralVault vault = CollateralVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        Harvester harvester = new Harvester(address(subLoop), PRIME, GOV);

        vm.stopBroadcast();

        console.log("SubLoop (proxy):", address(subLoop));
        console.log("CollateralVault (proxy):", address(vault));
        console.log("Harvester:", address(harvester));
        console.log("synth:", synth);
    }
}
