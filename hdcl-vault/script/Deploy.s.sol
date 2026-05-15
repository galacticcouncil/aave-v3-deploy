// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HDCLVault} from "../src/HDCLVault.sol";
import {WDCLOracle} from "../src/WDCLOracle.sol";

contract Deploy is Script {
    // Hydration mainnet addresses
    address constant DECENTRAL_POOL = 0x207a626c07b73E76134177D1f44B0f32e94ADB5a;
    address constant POOL_TOKEN = 0xC91808c129C9766b13D22c9f0cD53Db459c0bc48;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    uint256 constant TVL_CAP = 2_000_000e18;

    function run() external {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        (address impl, address proxy, address oracle) = deployFromConfig(
            deployerKey,
            admin,
            DECENTRAL_POOL,
            POOL_TOKEN,
            HOLLAR,
            TVL_CAP
        );

        console.log("Implementation:", impl);
        console.log("Proxy (HDCL Vault):", proxy);
        console.log("WDCLOracle:", oracle);
    }

    /// @notice Deploy + wire oracle in one shot. Returns the three deployed addresses.
    /// @dev Extracted from run() so tests can exercise the full deploy path with
    ///      mock pool/token/hollar addresses without touching env vars or hardcoded
    ///      mainnet addresses. setOracle is admin-gated, so the deployer must hold
    ///      ADMIN_ROLE — i.e. vm.addr(deployerKey) == admin. The require() catches
    ///      this at deploy time instead of failing inside setOracle.
    function deployFromConfig(
        uint256 deployerKey,
        address admin,
        address decentralPool,
        address poolToken,
        address hollarToken,
        uint256 tvlCap
    ) public returns (address impl, address proxy, address oracle) {
        require(
            vm.addr(deployerKey) == admin,
            "Deployer must equal ADMIN_ADDRESS to wire oracle inline"
        );

        vm.startBroadcast(deployerKey);

        HDCLVault implementation = new HDCLVault();
        bytes memory initData = abi.encodeCall(
            HDCLVault.initialize,
            (decentralPool, poolToken, hollarToken, tvlCap, admin)
        );
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            address(implementation),
            initData
        );
        HDCLVault vault = HDCLVault(address(proxyContract));

        // Deploy the price feed and wire it into the vault.
        WDCLOracle oracleContract = new WDCLOracle(address(vault));
        vault.setOracle(address(oracleContract));

        // Sanity check: getOraclePrice must succeed end-to-end before we
        // declare the deploy successful. Catches "oracle not wired" and
        // permission-mismatch failures at deploy time, not in production.
        require(
            vault.getOraclePrice() > 0,
            "Oracle wiring failed: getOraclePrice returned 0"
        );

        vm.stopBroadcast();

        return (
            address(implementation),
            address(proxyContract),
            address(oracleContract)
        );
    }
}
