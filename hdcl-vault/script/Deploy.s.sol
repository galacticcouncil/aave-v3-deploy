// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HDCLVault} from "../src/HDCLVault.sol";

contract Deploy is Script {
    // Hydration mainnet addresses
    address constant DECENTRAL_POOL = 0x207a626c07b73E76134177D1f44B0f32e94ADB5a;
    address constant POOL_TOKEN = 0xC91808c129C9766b13D22c9f0cD53Db459c0bc48;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    uint256 constant TVL_CAP = 2_000_000e18;

    function run() external {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        HDCLVault implementation = new HDCLVault();
        bytes memory initData = abi.encodeCall(
            HDCLVault.initialize,
            (DECENTRAL_POOL, POOL_TOKEN, HOLLAR, TVL_CAP, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        vm.stopBroadcast();
        console.log("Implementation:", address(implementation));
        console.log("Proxy (HDCL Vault):", address(proxy));
    }
}
