// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ClampedOracle} from "../../contracts/ClampedOracle.sol";

contract _Create2Factory {
    function deploy(
        bytes32 salt,
        bytes memory initCode
    ) external returns (address addr) {
        require(initCode.length != 0, "empty initCode");
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(addr != address(0), "CREATE2 failed");
    }
}

contract DeployClampedOracle is Script {
    function run() external {
        address primaryFeed = vm.envAddress("PRIMARY_FEED");
        address secondaryFeed = vm.envAddress("SECONDARY_FEED");
        uint256 maxDiffBps = vm.envUint("MAX_DIFF_BPS");
        bytes32 salt = vm.envOr("SALT", bytes32(0));

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerEOA = vm.addr(deployerPrivateKey);

        bytes memory initCode = _oracleInitCode(
            primaryFeed,
            secondaryFeed,
            maxDiffBps
        );
        bytes32 initCodeHash = keccak256(initCode);

        console.log("Deploying ClampedOracle via native CREATE2");
        console.log("  From EOA:", deployerEOA);
        console.log("  Primary Feed:", primaryFeed);
        console.log("  Secondary Feed:", secondaryFeed);
        console.log("  Max Diff BPS:", maxDiffBps);
        console.log("  Salt:", vm.toString(salt));

        vm.startBroadcast(deployerPrivateKey);

        _Create2Factory factory = new _Create2Factory();
        console.log("  Factory:", address(factory));

        address predicted = computeCreate2Address(
            address(factory),
            salt,
            initCodeHash
        );
        console.log("  Predicted Address:", predicted);

        if (predicted.code.length == 0) {
            address deployed = factory.deploy(salt, initCode);
            require(deployed == predicted, "deployed != predicted");
        } else {
            console.log(
                "  Already deployed at predicted address, skipping deploy"
            );
        }

        vm.stopBroadcast();

        require(
            predicted.code.length > 0,
            "Deployment failed: no code at predicted address"
        );
        console.log("ClampedOracle deployed at:", predicted);
    }

    function _oracleInitCode(
        address primaryFeed,
        address secondaryFeed,
        uint256 maxDiffBps
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                type(ClampedOracle).creationCode,
                abi.encode(primaryFeed, secondaryFeed, maxDiffBps)
            );
    }

    function computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) public pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }
}
