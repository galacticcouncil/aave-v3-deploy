// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {Harvester} from "../src/Harvester.sol";

/// @notice Deploy the role-free Harvester (full-balance distribution +
///         pro-rata completeness check). Non-proxy → this replaces the old
///         Harvester. After deploy, governance wires it via a Root referendum:
///         SubLoop.setHarvester(this), Harvester.addVault(vault) — see
///         scripts/propeller-wire-keeperless-lark.mjs.
///
///         lark-2 args mirror DeployLark.s.sol L73: (subLoop, DCL, GOV).
///         DCL stands in for PRIME on lark-2 (the token SubLoop.harvest emits).
///
///         forge script script/DeployHarvester.s.sol:DeployHarvester \
///           --rpc-url https://2.lark.hydration.cloud --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeployHarvester is Script {
    address constant SUBLOOP = 0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8;
    address constant DCL = 0x0000000000000000000000000000000100000226; // = SubLoop's "prime" on lark-2
    address constant GOV = 0xAa7e0000000000000000000000000000000Aa7e0;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        // Overridable per-chain (else lark-2 defaults). PRIME is the token
        // SubLoop.harvest emits (DCL on lark-2). On lark-4 pass SUBLOOP + PRIME.
        address subLoop = vm.envOr("SUBLOOP", SUBLOOP);
        address prime = vm.envOr("PRIME", DCL);
        address gov = vm.envOr("GOV", GOV);
        vm.startBroadcast(deployerKey);
        Harvester h = new Harvester(subLoop, prime, gov);
        vm.stopBroadcast();
        console2.log("Harvester:", address(h));
    }
}
