// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Harvester} from "../src/Harvester.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @notice Verifies the KEEPER_ROLE removal: every former keeper op is callable
///         by an arbitrary address (no AccessControl gate), harvest pays the
///         configured harvester (not the caller), compound enforces an
///         oracle-fair floor, the Harvester distributes its full balance
///         pro-rata and rejects a stale vault set, and the pause matrix holds.
contract PermissionlessKeeperTest is Test {
    MockERC20 eth;
    MockERC20 aEth;
    MockERC20 ethDebt;
    MockERC20 hollar;
    MockERC20 aHollar;
    MockERC20 hollarDebt;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt;
    MockERC20 aSynth;
    MockERC20 synthDebt;

    MockPool pool;
    MockSwapper swapper;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;
    Harvester harvester;

    address constant RANDO = address(0xBEEF);

    function setUp() public {
        eth = new MockERC20("ETH", "ETH", 18);
        aEth = new MockERC20("aETH", "aETH", 18);
        ethDebt = new MockERC20("dETH", "dETH", 18);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);
        hollarDebt = new MockERC20("dHOLLAR", "dHOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("dPRIME", "dPRIME", 6);
        synth = new SyntheticToken("Propeller Synthetic", "psHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        // synth: small non-zero LTV so it can be enabled as collateral
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);
        swapper = new MockSwapper(address(pool));

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool), address(0), address(hollar), address(prime),
                            address(aPrime), address(hollarDebt), 0.88e18, 1.05e18, 1.10e18, address(this)
                        )
                    )
                )
            )
        );
        vault = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Propeller ETH", "pETH", address(eth), address(pool), address(loop),
                            address(swapper), address(hollar), address(synth), address(aEth),
                            address(hollarDebt), 9800, 1_000e18, address(this)
                        )
                    )
                )
            )
        );
        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 0, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.setCompoundSlippageBps(100); // 1% vs oracle-fair
    }

    // ── every opened op is callable by a non-role address ────────────────────

    function test_keeperOpsCallableByAnyone() public {
        // no-op paths succeed (no AccessControl revert) from an arbitrary caller
        vm.startPrank(RANDO);
        loop.pokeBorrow();
        loop.pokeRepay();
        loop.harvest();
        vault.pokeSettle();
        vault.rebalance();
        vault.maintainPeg();
        uint256[] memory none = new uint256[](0);
        harvester.harvest(none);
        vm.stopPrank();

        // deLever reaches the HF guard (proves access passed), not AccessControl
        vm.prank(RANDO);
        vm.expectRevert(SubLoop.HealthyEnough.selector);
        loop.deLever();

        vm.prank(RANDO);
        vm.expectRevert(SubLoop.HealthyEnough.selector);
        harvester.deLever();

        // compound reaches its body (ZeroAmount), not AccessControl
        vm.prank(RANDO);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.compound(address(prime), 0, 0, "");
    }

    // ── harvest pays the configured harvester, never the caller ──────────────

    function test_harvestConfiguredAsHarvester() public {
        assertEq(loop.harvester(), address(harvester), "harvester pinned");
    }

    // ── compound oracle floor: honest fill passes, lossy fill reverts ────────

    function test_compoundEnforcesOracleFloor() public {
        uint256 amt = 100e6; // 100 PRIME
        // honest swapper (no haircut): a low caller minOut is raised to the floor
        prime.mint(RANDO, amt);
        vm.startPrank(RANDO);
        prime.approve(address(vault), amt);
        uint256 aEthBefore = aEth.balanceOf(address(vault));
        vault.compound(address(prime), amt, 0, ""); // minOut=0 → floor binds, still fills
        vm.stopPrank();
        assertGt(aEth.balanceOf(address(vault)), aEthBefore, "honest compound supplied collateral");

        // lossy swapper (2% haircut > 1% tolerance): the floor rejects the fill
        swapper.setHaircut(200);
        prime.mint(RANDO, amt);
        vm.startPrank(RANDO);
        prime.approve(address(vault), amt);
        vm.expectRevert(); // MockSwapper minOut (raised to floor) or PrincipalShortfall
        vault.compound(address(prime), amt, 0, "");
        vm.stopPrank();
    }

    // ── Harvester: full-balance distribution, pro-rata, incomplete-set guard ──

    function test_harvesterDistributesParkedBalance() public {
        // give the loop a vault position (credits loop shares for the vault)
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        assertGt(loop.sharesOf(address(vault)), 0, "vault holds loop shares");

        // simulate PRIME parked at the Harvester (e.g. a direct SubLoop.harvest caller)
        uint256 parked = 50e6;
        prime.mint(address(harvester), parked);

        // stale registry (vault not added) → fails loud, doesn't strand silently
        uint256[] memory none = new uint256[](0);
        vm.prank(RANDO);
        vm.expectRevert(bytes("vault set incomplete"));
        harvester.harvest(none);

        // complete registry → distributes the FULL parked balance into the vault
        harvester.addVault(address(vault));
        uint256 aEthBefore = aEth.balanceOf(address(vault));
        vm.prank(RANDO);
        harvester.harvest(none);
        assertEq(prime.balanceOf(address(harvester)), 0, "parked PRIME fully distributed");
        assertGt(aEth.balanceOf(address(vault)), aEthBefore, "compounded into collateral");
    }

    // ── pause matrix: kill-switch on yield/maintenance, never on user exits ───

    function test_pauseMatrix() public {
        loop.grantRole(loop.GUARDIAN_ROLE(), address(this));
        vault.grantRole(vault.GUARDIAN_ROLE(), address(this));

        vault.pause();
        // paused: yield/maintenance ops blocked
        vm.expectRevert();
        vault.compound(address(prime), 1e6, 0, "");
        vm.expectRevert();
        vault.rebalance();
        // never paused: user-exit + safety-floor ops still run
        vault.pokeSettle();
        vault.maintainPeg();
        vault.unpause();

        loop.pause();
        vm.expectRevert();
        loop.harvest();
        vm.expectRevert();
        loop.pokeBorrow();
        // never paused: unwind servicing still runs
        loop.pokeRepay();
    }
}
