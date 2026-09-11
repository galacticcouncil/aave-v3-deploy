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
import {MockSwapper} from "./mocks/MockSwapper.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice Configuration surface that must fail closed or follow governance rather
///         than drift: the swap seam, the synthetic's liquidation threshold, the
///         carry recipient, and the harvest distribution registry.
contract AdminConfigTest is Test {
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
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;
    Harvester harvester;

    address stranger = address(0xBAD);

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
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (address(pool), address(hollar), address(prime), address(aPrime), 1.05e18, 1.10e18, address(this))
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
                            "Propeller ETH",
                            "pETH",
                            address(eth),
                            address(pool),
                            address(loop),
                            address(0),
                            address(hollar),
                            address(synth),
                            address(aEth),
                            address(hollarDebt),
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );

        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function _deposit() internal {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
    }

    // ── swap seam ────────────────────────────────────────────────────────────

    /// REQ-SWAP (HydraAugustus) is not deployed on mainnet, so deploy scripts pass a
    /// placeholder. Without a setter, pointing at the real swapper later would need a
    /// UUPS upgrade of every vault — `script/DeployMain.s.sol` already documents this
    /// function as existing.
    function test_setSwapperRepointsWithoutUpgrade() public {
        assertEq(address(vault.swapper()), address(0), "placeholder at deploy");
        MockSwapper s = new MockSwapper(address(pool));
        vault.setSwapper(address(s));
        assertEq(address(vault.swapper()), address(s), "repointed");
    }

    function test_setSwapperRejectsZeroAndStrangers() public {
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.setSwapper(address(0));

        MockSwapper s = new MockSwapper(address(pool));
        vm.prank(stranger);
        vm.expectRevert();
        vault.setSwapper(address(s));
    }

    // ── synthetic liquidation threshold ──────────────────────────────────────

    /// INV-1 (`syntheticSupplied · synthLt ≥ mainDebt`) is the un-liquidatable
    /// principal guard. Reading the threshold live means a governance retune of the
    /// synth reserve is followed immediately instead of leaving the guard checking a
    /// stale-high copy while the real Aave floor no longer covers the debt.
    function test_synthLtFollowsGovernance() public {
        assertEq(vault.synthLtBps(), 9800, "reads the live reserve config");

        _deposit();
        uint256 synthAt9800 = vault.syntheticSupplied();

        // Governance tightens the synthetic reserve.
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 5000, 100, 18, 1e18);
        assertEq(vault.synthLtBps(), 5000, "vault follows the change with no admin call");

        // maintainPeg now tops the floor up against the NEW threshold.
        vault.maintainPeg();
        uint256 synthAt5000 = vault.syntheticSupplied();
        assertGt(synthAt5000, synthAt9800, "floor re-provisioned at the lower LT");

        uint256 debt = hollarDebt.balanceOf(address(vault));
        assertGe(synthAt5000 * 5000 / 1e4, debt, "INV-1 holds against the live threshold");
    }

    /// The synthetic reserve is listed by the governance proposal AFTER the contracts
    /// are deployed. Until then its LT is 0 and the floor cannot be established —
    /// deposits must say so rather than panic on a division by zero.
    function test_depositFailsClosedBeforeSynthReserveIsListed() public {
        MockPool bare = new MockPool();
        bare.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        bare.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        // synth deliberately NOT listed

        CollateralVault v = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Propeller ETH", "pETH", address(eth), address(bare), address(loop),
                            address(0), address(hollar), address(synth), address(aEth),
                            address(hollarDebt), 1_000e18, address(this)
                        )
                    )
                )
            )
        );

        vm.expectRevert(CollateralVault.SynthReserveNotListed.selector);
        v.synthLtBps();

        eth.mint(address(this), 1e18);
        eth.approve(address(v), 1e18);
        vm.expectRevert(CollateralVault.SynthReserveNotListed.selector);
        v.deposit(1e18, address(this));
    }

    // ── carry recipient ──────────────────────────────────────────────────────

    /// `initialize` never assigns a harvester. An earlier fallback paid `msg.sender`
    /// when it was unset, making the entire loop carry claimable by anyone in the
    /// deploy-to-wiring window.
    function test_harvestFailsClosedWhileHarvesterUnset() public {
        assertEq(loop.harvester(), address(0), "unset at deploy");

        // Build real carry: ramp the loop, then let PRIME appreciate so live equity
        // exceeds the HOLLAR cost basis. Without surplus `harvest` is a no-op and
        // there is nothing to misroute — the window only exists once carry accrues.
        _deposit();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
        pool.setPrice(address(prime), 1.10e18);
        assertGt(loop.totalEquity() * 1e10, loop.principalEquity(), "carry accrued");

        vm.expectRevert(SubLoop.HarvesterUnset.selector);
        loop.harvest();

        // and once wired, the same call pays the harvester — never the caller
        uint256 before = prime.balanceOf(address(this));
        loop.setHarvester(address(harvester));
        loop.harvest();
        assertEq(prime.balanceOf(address(this)), before, "caller paid nothing");
        assertGt(prime.balanceOf(address(harvester)), 0, "carry routed to the harvester");
    }

    function test_setHarvesterRejectsZero() public {
        loop.setHarvester(address(harvester));
        assertEq(loop.harvester(), address(harvester));

        // re-zeroing would silently disable carry realisation for every vault
        vm.expectRevert(SubLoop.ZeroAddress.selector);
        loop.setHarvester(address(0));
    }

    // ── harvest distribution registry ────────────────────────────────────────

    /// `harvest` sums `sharesOf(v)` per registry entry and hard-requires the total to
    /// equal `subLoop.totalShares()`. A vault listed twice double-counts and reverts
    /// every harvest — permanently, because Harvester is not upgradeable.
    function test_addVaultRejectsDuplicates() public {
        harvester.addVault(address(vault));
        assertEq(harvester.vaultCount(), 1);

        vm.expectRevert(Harvester.AlreadyRegistered.selector);
        harvester.addVault(address(vault));
        assertEq(harvester.vaultCount(), 1, "registry unchanged");
    }

    function test_removeVaultKeepsRegistryConsistent() public {
        address other = address(0xBEEF);
        harvester.addVault(address(vault));
        harvester.addVault(other);
        assertEq(harvester.vaultCount(), 2);

        harvester.removeVault(address(vault));
        assertEq(harvester.vaultCount(), 1, "swap-removed");
        assertEq(harvester.vaults(0), other, "survivor moved into the freed slot");
        assertFalse(harvester.isRegistered(address(vault)));

        // and it can be re-added afterwards
        harvester.addVault(address(vault));
        assertEq(harvester.vaultCount(), 2);
    }

    function test_removeVaultRejectsUnregistered() public {
        vm.expectRevert(Harvester.NotRegistered.selector);
        harvester.removeVault(address(vault));
    }

    function test_registryIsAdminOnly() public {
        vm.prank(stranger);
        vm.expectRevert();
        harvester.addVault(address(vault));

        harvester.addVault(address(vault));
        vm.prank(stranger);
        vm.expectRevert();
        harvester.removeVault(address(vault));
    }
}
