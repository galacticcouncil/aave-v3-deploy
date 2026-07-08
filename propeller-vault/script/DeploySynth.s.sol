// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";

/// @notice Deploy just the Propeller SyntheticToken (the reserve the governance
///         proposal lists). Admin is set to the governance aave-manager so the
///         single Root proposal can grant MINTER_ROLE to the vault etc.
///
///         forge script script/DeploySynth.s.sol:DeploySynth \
///           --rpc-url https://2.lark.hydration.cloud --broadcast \
///           --evm-version london --legacy --slow --gas-estimate-multiplier 200
contract DeploySynth is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        // governance owner (aave-manager precompile) by default
        address admin = vm.envOr("ADMIN_ADDRESS", address(0xAa7e0000000000000000000000000000000Aa7e0));

        vm.startBroadcast(deployerKey);
        SyntheticToken synth = new SyntheticToken("Propeller Synthetic HOLLAR", "psHOLLAR", admin);
        vm.stopBroadcast();

        console.log("SyntheticToken:", address(synth));
        console.log("admin (governance):", admin);
    }
}
