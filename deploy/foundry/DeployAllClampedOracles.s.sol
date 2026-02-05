// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ClampedOracle} from "../../contracts/ClampedOracle.sol";

contract DeployAllClampedOracles is Script {
    // Arachnid deterministic deployment proxy (SingletonFactory)
    address internal constant CREATE2_PROXY =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address primaryFeed = vm.envAddress("PRIMARY_FEED");
        address secondaryFeed = vm.envAddress("SECONDARY_FEED");
        uint256 maxDiffBps = vm.envUint("MAX_DIFF_BPS");
        bytes32 salt = vm.envBytes32("SALT");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerEOA = vm.addr(deployerPrivateKey);

        require(primaryFeed != address(0), "PRIMARY_FEED=0");
        require(secondaryFeed != address(0), "SECONDARY_FEED=0");
        require(maxDiffBps > 0, "MAX_DIFF_BPS=0");
        require(maxDiffBps <= 10_000, "MAX_DIFF_BPS>10000");

        require(CREATE2_PROXY.code.length != 0, "CREATE2 proxy not deployed");

        bytes memory initCode = _oracleInitCode(
            primaryFeed,
            secondaryFeed,
            maxDiffBps
        );
        require(initCode.length != 0, "initCode empty");
        bytes32 initCodeHash = keccak256(initCode);

        address predicted = computeCreate2Address(
            CREATE2_PROXY,
            salt,
            initCodeHash
        );

        console.log("Deploying ClampedOracle via CREATE2 proxy");
        console.log("  Broadcaster (EOA):", deployerEOA);
        console.log("  CREATE2 deployer (proxy):", CREATE2_PROXY);
        console.log("  Primary Feed:", primaryFeed);
        console.log("  Secondary Feed:", secondaryFeed);
        console.log("  Max Diff BPS:", maxDiffBps);
        console.log("  Salt:", vm.toString(salt));
        console.log("  Predicted Address:", predicted);

        require(predicted.code.length == 0, "already deployed");

        vm.startBroadcast(deployerPrivateKey);

        address deployed = _deployViaCreate2Proxy(salt, initCode);

        require(deployed == predicted, "deployed != predicted");

        require(deployed.code.length != 0, "no code at deployed");

        vm.stopBroadcast();

        console.log("  Status: DEPLOYED");
        console.log("JSON_OUTPUT:", predicted);
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

    function _deployViaCreate2Proxy(
        bytes32 salt,
        bytes memory initCode
    ) internal returns (address deployed) {
        require(initCode.length != 0, "empty initCode");

        bytes memory data = abi.encodePacked(salt, initCode);
        (bool ok, bytes memory ret) = CREATE2_PROXY.call(data);

        require(ok, "proxy call failed");
        require(ret.length == 20, "proxy bad return");

        deployed = address(bytes20(ret));
        require(deployed != address(0), "proxy returned 0");
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
