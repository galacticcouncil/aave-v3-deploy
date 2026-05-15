// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {WDCLOracle} from "../../src/WDCLOracle.sol";
import {MockHollar} from "../mocks/MockHollar.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

/// @title Deploy Script Regression Coverage
/// @notice Verifies the deploy script wires the oracle end-to-end.
///         Pre-fix, the script deployed the vault but never deployed/set the
///         WDCLOracle, so `getOraclePrice()` reverted in production until
///         someone manually completed the wiring.
contract DeployTest is Test {
    Deploy internal deployScript;
    MockHollar internal hollar;
    MockPoolToken internal nft;
    MockDecentralPool internal pool;

    uint256 internal constant APY_18_PERCENT = 0.18e18;
    uint256 internal constant TVL_CAP = 2_000_000e18;

    function setUp() public {
        // Deploy the mock back-ends the vault will integrate with.
        hollar = new MockHollar();
        nft = new MockPoolToken();
        pool = new MockDecentralPool(address(hollar), address(nft), APY_18_PERCENT);
        nft.registerPool(address(pool));
        hollar.mint(address(pool), 10_000_000e18);

        deployScript = new Deploy();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   CORE: deploy script wires the oracle
    // ═══════════════════════════════════════════════════════════════════════

    function test_deploy_wiresOracleAndPasswordsSanityCheck() public {
        uint256 deployerKey = uint256(keccak256("admin-deployer"));
        address admin = vm.addr(deployerKey);

        (address impl, address proxy, address oracle) = deployScript.deployFromConfig(
            deployerKey,
            admin,
            address(pool),
            address(nft),
            address(hollar),
            TVL_CAP
        );

        // All three deployed
        assertTrue(impl != address(0), "implementation deployed");
        assertTrue(proxy != address(0), "proxy deployed");
        assertTrue(oracle != address(0), "oracle deployed");

        // Three distinct addresses
        assertTrue(impl != proxy, "impl != proxy");
        assertTrue(proxy != oracle, "proxy != oracle");

        HDCLVault vault = HDCLVault(proxy);
        WDCLOracle wdcl = WDCLOracle(oracle);

        // Oracle wired into the vault
        assertEq(address(vault.oracle()), oracle, "vault.oracle() points at the deployed oracle");

        // Oracle points at the vault
        assertEq(address(wdcl.vault()), proxy, "oracle.vault() points back at the proxy");

        // Vault is initialized with the right back-ends
        assertEq(address(vault.decentralPool()), address(pool), "decentralPool wired");
        assertEq(address(vault.poolToken()), address(nft), "poolToken wired");
        assertEq(address(vault.hollar()), address(hollar), "hollar wired");
        assertEq(vault.tvlCap(), TVL_CAP, "tvlCap set");

        // Admin role granted
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), admin), "admin has ADMIN_ROLE");
        assertTrue(vault.hasRole(vault.UPGRADER_ROLE(), admin), "admin has UPGRADER_ROLE");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "admin has DEFAULT_ADMIN_ROLE");
    }

    /// @notice The core regression: getOraclePrice must succeed right after deploy.
    ///         Pre-fix, this would revert with "Oracle not set" because the script
    ///         never wired the oracle.
    function test_deploy_getOraclePriceWorksImmediately() public {
        uint256 deployerKey = uint256(keccak256("admin-deployer-2"));
        address admin = vm.addr(deployerKey);

        (, address proxy,) = deployScript.deployFromConfig(
            deployerKey,
            admin,
            address(pool),
            address(nft),
            address(hollar),
            TVL_CAP
        );

        HDCLVault vault = HDCLVault(proxy);
        uint256 price = vault.getOraclePrice();
        assertGt(price, 0, "getOraclePrice must return > 0 after deploy");
        // At zero supply the rate is 1e18 (1:1); getOraclePrice scales 8d → 18d.
        assertApproxEqRel(price, 1e18, 0.001e18, "deploy-time price ~ 1e18");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   GUARD: deployer != admin reverts cleanly
    // ═══════════════════════════════════════════════════════════════════════

    function test_deploy_revertsWhenDeployerIsNotAdmin() public {
        uint256 deployerKey = uint256(keccak256("not-the-admin"));
        address admin = makeAddr("different-admin");

        vm.expectRevert("Deployer must equal ADMIN_ADDRESS to wire oracle inline");
        deployScript.deployFromConfig(
            deployerKey,
            admin,
            address(pool),
            address(nft),
            address(hollar),
            TVL_CAP
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   END-TO-END: vault is fully usable after deploy (deposit + redeem)
    // ═══════════════════════════════════════════════════════════════════════

    function test_deploy_vaultIsImmediatelyUsable() public {
        uint256 deployerKey = uint256(keccak256("admin-deployer-3"));
        address admin = vm.addr(deployerKey);

        (, address proxy,) = deployScript.deployFromConfig(
            deployerKey,
            admin,
            address(pool),
            address(nft),
            address(hollar),
            TVL_CAP
        );

        HDCLVault vault = HDCLVault(proxy);

        // A fresh user deposits and gets HDCL back
        address alice = makeAddr("alice");
        hollar.mint(alice, 10_000e18);
        vm.prank(alice);
        hollar.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        uint256 hdclMinted = vault.deposit(10_000e18);
        assertGt(hdclMinted, 0, "first deposit mints HDCL");

        // Oracle still works after a real deposit
        uint256 price = vault.getOraclePrice();
        assertGt(price, 0, "oracle works after deposit");
    }
}
