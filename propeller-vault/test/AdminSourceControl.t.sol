// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice Admin control over which yield source the vault routes into.
///
///   `setYieldSource(new)` (ADMIN_ROLE) repoints the vault, and is allowed ONLY
///   when the current source owes this vault nothing at all: no live shares,
///   nothing freed-but-unpulled, no in-flight unwind. That makes it a wiring
///   lever (fresh vault, or after every holder has exited through the normal
///   redemption queue) rather than an emergency one.
///
///   There is deliberately NO admin path that force-unwinds a live position out
///   of its source. An earlier `adminUnwind()` did exactly that — pausing the
///   vault, de-risking everyone to bare collateral, and relying on a relative
///   drain tolerance to decide when the old source counted as empty. It was
///   removed: it locked non-redeeming holders behind a guard that realized
///   slippage could make unsatisfiable, and its tolerance scaled with position
///   size rather than being true dust. To abandon a funded source now: `pause()`
///   to stop new flow, let holders redeem, then repoint.
contract AdminSourceControlTest is Test {
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

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(address(pool), address(hollar), address(prime), 222, 1043);
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function _depositAndRamp() internal {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    // drive the unwind spiral + settle until the position is fully drained
    function _drain() internal {
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
    }


    /// A fresh vault has never routed HOLLAR into a source, so repointing is
    /// trivially safe — this is the wiring use of `setYieldSource`.
    function test_setYieldSourceOnFreshVault() public {
        MockYieldSource next = new MockYieldSource(address(hollar));
        vault.setYieldSource(address(next));
        assertEq(address(vault.yieldSource()), address(next), "source repointed");
    }

    /// Once a deposit has funded the source, repointing must refuse: the old
    /// source holds this vault's shares and abandoning it would strand them.
    function test_setYieldSourceRevertsWhileFunded() public {
        _depositAndRamp();
        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setYieldSource(address(next));
    }

    /// With an unwind in flight the old source still owes the vault equity it has
    /// not yet freed. Swapping now would strand that HOLLAR, so the guard must
    /// refuse until `pendingUnwindOf` is exactly zero.
    function test_setYieldSourceGuardsInFlightUnwind() public {
        _depositAndRamp();
        vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        assertGt(loop.pendingUnwindOf(address(vault)), 0, "source still owes the vault in-flight");

        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setYieldSource(address(next));
    }

    /// A funded vault can NEVER be repointed, even after every holder has exited.
    /// `DEAD_SHARES` stay locked in `totalSupply`, so each `requestRedeem` unwinds
    /// only `loopShares · shares / supply` and always leaves the dead shares'
    /// proportional slice behind — `loopShares` never returns to exactly 0.
    ///
    /// This is the documented boundary of the lever, asserted so it cannot drift
    /// into looking like a migration path: to change a live vault's yield source,
    /// deploy a new vault and let holders migrate through the redemption queue.
    function test_setYieldSourceUnreachableOnceFunded() public {
        _depositAndRamp();
        uint256 id = vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        for (uint256 i = 0; i < 2_000; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
            vault.pokeSettle();
        }
        vault.pokeSettle();
        vault.claim(id, address(this));

        assertEq(vault.balanceOf(address(this)), 0, "holder fully exited");
        assertEq(loop.pendingUnwindOf(address(vault)), 0, "source owes nothing in flight");
        assertGt(vault.loopShares(), 0, "but the DEAD_SHARES slice remains, forever");

        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(CollateralVault.SourceNotEmpty.selector);
        vault.setYieldSource(address(next));
    }

    function test_onlyAdminControls() public {
        MockYieldSource next = new MockYieldSource(address(hollar));

        vm.prank(stranger);
        vm.expectRevert();
        vault.setYieldSource(address(next));

        vm.prank(stranger);
        vm.expectRevert();
        vault.setTvlCap(1);

        vm.prank(stranger);
        vm.expectRevert();
        vault.setCompoundSlippageBps(100);
    }
}
