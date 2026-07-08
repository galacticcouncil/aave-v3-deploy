// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {CollateralVault} from "../src/CollateralVault.sol";

/// @notice Deploy a fresh CollateralVault *implementation* (no proxy, no init)
///         for a UUPS upgrade of the existing vault proxy. The proxy's
///         UPGRADER_ROLE is held by GOV, so the swap is done by a Root
///         referendum that calls `upgradeTo(newImpl)` — see
///         scripts/propeller-upgrade-vault-lark.mjs.
///
///         forge script script/DeployVaultImpl.s.sol:DeployVaultImpl \
///           --rpc-url https://2.lark.hydration.cloud --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeployVaultImpl is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        CollateralVault impl = new CollateralVault();
        vm.stopBroadcast();
        console2.log("CollateralVault impl:", address(impl));
    }
}
