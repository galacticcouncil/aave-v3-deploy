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

/// @notice Phase C: admin controls to wind down and swap the yield source.
///   - `adminUnwind()` (ADMIN_ROLE): winds the vault's whole loop position out of
///     the current source and routes the freed HOLLAR to repay Main debt — i.e.
///     de-risks users to bare collateral (Option 1), reusing the existing
///     deleverTarget → pokeSettle machinery. The human decides WHEN; the contract
///     never auto-triggers this.
///   - `setYieldSource(new)` (ADMIN_ROLE): repoints the vault to a new source,
///     allowed only once the current source is fully drained (no shares, nothing
///     freed-but-unpulled) so no funds are stranded.
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
                            9800,
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

    function test_adminUnwindDeRisksToBareCollateral() public {
        _depositAndRamp();
        assertGt(hollarDebt.balanceOf(address(vault)), 0, "has Main debt before");
        assertGt(vault.syntheticSupplied(), 0, "has synth before");

        vault.adminUnwind();
        _drain();

        // Main debt repaid and synth burned to dust (the unwind spiral leaves the
        // same benign sub-HOLLAR remainder the integration test allows for) — but
        // the ETH collateral is untouched: users are left holding bare collateral,
        // no leverage, no venue exposure. (Started at ~2250 HOLLAR of debt.)
        assertLt(hollarDebt.balanceOf(address(vault)), 1e18, "Main debt repaid (2250 to <1)");
        assertLt(vault.syntheticSupplied(), 1e18, "synth burned");
        assertApproxEqRel(aEth.balanceOf(address(vault)), 1e18, 0.01e18, "collateral intact");
        assertEq(loop.equityOf(address(vault)), 0, "no equity left in the source");
    }

    function test_setYieldSourceRevertsWhileFunded() public {
        _depositAndRamp();
        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(); // SourceNotEmpty — funds still in the old source
        vault.setYieldSource(address(next));
    }

    function test_setYieldSourceSucceedsOnceDrained() public {
        _depositAndRamp();
        vault.adminUnwind();
        _drain();

        MockYieldSource next = new MockYieldSource(address(hollar));
        vault.setYieldSource(address(next));
        assertEq(address(vault.yieldSource()), address(next), "source repointed");

        // new deposits now route into the new source
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        assertGt(next.sharesOf(address(vault)), 0, "new deposits fund the new source");
    }

    /// After adminUnwind requests the unwind but BEFORE the spiral has freed and
    /// the vault has pulled it, the old source still owes the vault its in-flight
    /// equity. Swapping now would strand that HOLLAR in the abandoned source, so
    /// setYieldSource must refuse until the drain is actually complete.
    function test_setYieldSourceGuardsInFlightUnwind() public {
        _depositAndRamp();
        vault.adminUnwind(); // requests unwind of everything — but no pokeRepay/pokeSettle yet
        assertGt(loop.unwindRequested(address(vault)), 0, "source still owes the vault in-flight");

        MockYieldSource next = new MockYieldSource(address(hollar));
        vm.expectRevert(); // SourceNotEmpty — must not swap while the old source still owes us
        vault.setYieldSource(address(next));
    }

    function test_onlyAdminControls() public {
        _depositAndRamp();
        MockYieldSource next = new MockYieldSource(address(hollar));

        vm.prank(stranger);
        vm.expectRevert();
        vault.adminUnwind();

        vm.prank(stranger);
        vm.expectRevert();
        vault.setYieldSource(address(next));
    }
}
