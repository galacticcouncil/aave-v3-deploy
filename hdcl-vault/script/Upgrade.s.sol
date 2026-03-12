// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {HDCLVault} from "../src/HDCLVault.sol";

contract Upgrade is Script {
    function run() external {
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        uint256 upgraderKey = vm.envUint("UPGRADER_PRIVATE_KEY");
        vm.startBroadcast(upgraderKey);

        HDCLVault newImpl = new HDCLVault();
        HDCLVault(proxyAddress).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();
        console.log("New implementation:", address(newImpl));
    }
}
