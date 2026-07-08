// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {SubLoop} from "../src/SubLoop.sol";

/// @notice Deploy a fresh SubLoop *implementation* (no proxy, no init) for a
///         UUPS upgrade of the existing proxy. The proxy's UPGRADER_ROLE is held
///         by GOV, so the swap is done by a Root referendum that calls
///         `upgradeTo(newImpl)` — see scripts/propeller-upgrade-subloop-lark.mjs.
///
///         forge script script/DeploySubLoopImpl.s.sol:DeploySubLoopImpl \
///           --rpc-url https://2.lark.hydration.cloud --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeploySubLoopImpl is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        SubLoop impl = new SubLoop();
        vm.stopBroadcast();
        console2.log("SubLoop impl:", address(impl));
    }
}
