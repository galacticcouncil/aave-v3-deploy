// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {Harvester} from "../src/Harvester.sol";

/// @notice Scaffold deploy. Wires SyntheticToken + SubLoop + Harvester + one
///         CollateralVault (ETH) against the live Hydration money market.
///
/// @dev    Live deploy is gated on REQ-SWAP (a real ISwapper / Augustus address)
///         and the governance proposal (synthetic reserve + HOLLAR discount +
///         caps) in aave-v3-deploy/tasks/proposals/propeller.ts.
contract Deploy is Script {
    // Verified Hydration mainnet (2026-06-05)
    address constant POOL = 0x1b02E051683b5cfaC5929C25E84adb26ECf87B38;
    address constant HOLLAR = 0x531a654d1696ED52e7275A8cede955E82620f99a;
    address constant PRIME = 0x000000000000000000000000000000010000002B; // asset 43
    address constant ETH = 0x0000000000000000000000000000000100000022; // asset 34

    uint256 constant TARGET_HF = 1.05e18;
    uint256 constant DELEVER_TRIGGER = 1.10e18;
    uint16 constant SYNTH_LT_BPS = 9800; // synthetic reserve liquidation threshold
    uint256 constant ETH_TVL_CAP = 1_000e18;

    function run() external {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address swapper = vm.envAddress("SWAPPER_ADDRESS"); // REQ-SWAP (vault harvest swaps)
        address primeAToken = vm.envAddress("PRIME_ATOKEN"); // aPRIME, from getReserveData
        address hollarDebtToken = vm.envAddress("HOLLAR_DEBT_TOKEN"); // HOLLAR varDebt, from getReserveData
        address ethAToken = vm.envAddress("ETH_ATOKEN"); // aETH, from getReserveData

        vm.startBroadcast(deployerKey);

        // 1. Synthetic collateral token
        SyntheticToken synth = new SyntheticToken("Propeller Synthetic HOLLAR", "psHOLLAR", admin);

        // 2. Shared SubLoop (behind a proxy)
        SubLoop loopImpl = new SubLoop();
        bytes memory loopInit = abi.encodeCall(
            SubLoop.initialize,
            (
                POOL,
                HOLLAR,
                PRIME,
                primeAToken,
                TARGET_HF,
                DELEVER_TRIGGER,
                admin
            )
        );
        SubLoop subLoop = SubLoop(address(new ERC1967Proxy(address(loopImpl), loopInit)));

        // 3. ETH CollateralVault (behind a proxy)
        CollateralVault vaultImpl = new CollateralVault();
        bytes memory vaultInit = abi.encodeCall(
            CollateralVault.initialize,
            (
                "Propeller ETH",
                "pETH",
                ETH,
                POOL,
                address(subLoop),
                swapper,
                HOLLAR,
                address(synth),
                ethAToken, // aETH, from getReserveData
                hollarDebtToken, // HOLLAR varDebt, from getReserveData
                SYNTH_LT_BPS,
                ETH_TVL_CAP,
                admin
            )
        );
        CollateralVault ethVault =
            CollateralVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        // 4. Harvester
        Harvester harvester = new Harvester(address(subLoop), PRIME, admin);

        vm.stopBroadcast();

        console.log("SyntheticToken:", address(synth));
        console.log("SubLoop (proxy):", address(subLoop));
        console.log("ETH CollateralVault (proxy):", address(ethVault));
        console.log("Harvester:", address(harvester));
        console.log("NOTE: post-deploy wiring (governance/admin):");
        console.log(" - synth.grantRole(MINTER_ROLE, ethVault)");
        console.log(" - subLoop: registerVault, setHarvester, setTranches, configureDca");
        console.log(" - ethVault.setCompoundSlippageBps; harvester.addVault");
        console.log(" - governance: register synth reserve LTV>0, HOLLAR discount, raise caps");
    }
}
