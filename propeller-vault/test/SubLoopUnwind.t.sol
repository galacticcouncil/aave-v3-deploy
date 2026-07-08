// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice Unwind flow: ramp a loop, then full-unwind via the deleveraging
///         spiral (pokeRepay sells an HF-safe aPRIME sliver and repays each
///         call). Asserts the seed equity is freed back to the vault and the
///         position fully drains, HF-safely. Plus: the safety deLever sizes a
///         debt-repay target and the same spiral restores target HF.
contract SubLoopUnwindTest is Test {
    MockERC20 hollar;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt;
    MockERC20 hollarDebt;
    MockERC20 aHollar;
    MockPool pool;
    SubLoop loop;

    uint256 constant SEED = 1_000e18;
    uint256 constant TARGET_HF = 1.05e18;

    function setUp() public {
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("debtPRIME", "dPRIME", 6);
        hollarDebt = new MockERC20("debtHOLLAR", "dHOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);

        pool = new MockPool();
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);

        SubLoop impl = new SubLoop();
        bytes memory init = abi.encodeCall(
            SubLoop.initialize,
            (
                address(pool),
                address(hollar),
                address(prime),
                address(aPrime),
                TARGET_HF,
                1.10e18,
                address(this)
            )
        );
        loop = SubLoop(address(new ERC1967Proxy(address(impl), init)));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        loop.registerVault(address(this));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function _ramp() internal {
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        loop.deposit(SEED);
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    function test_fullUnwindFreesSeedEquity() public {
        _ramp();
        assertApproxEqRel(loop.totalEquity(), 1_000e8, 0.02e18, "ramped equity ~ seed");

        // unwind everything — the spiral sells + repays a sliver per poke
        loop.requestUnwind(loop.sharesOf(address(this)));
        for (uint256 i = 0; i < 400; i++) {
            if (aPrime.balanceOf(address(loop)) == 0) break;
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }

        // position drained
        assertApproxEqAbs(aPrime.balanceOf(address(loop)), 0, 1e6, "collateral drained");
        assertApproxEqAbs(hollarDebt.balanceOf(address(loop)), 0, 1e18, "debt repaid");

        // seed equity freed back to the vault (~1000 HOLLAR)
        assertApproxEqRel(loop.freedOf(address(this)), 1_000e18, 0.02e18, "freed ~ seed");

        uint256 balBefore = hollar.balanceOf(address(this));
        uint256 pulled = loop.pullFreed();
        assertApproxEqRel(pulled, 1_000e18, 0.02e18, "pulled ~ seed");
        assertEq(hollar.balanceOf(address(this)) - balBefore, pulled, "HOLLAR received");
    }

    /// bug D regression: deLever is no longer a stub — it sizes a repay target
    /// off (targetHf·debt − lt·coll)/(targetHf − lt) and pokeRepay's spiral
    /// repays loop debt with the FULL proceeds (no payout) until HF ≈ target.
    function test_deLeverRestoresTargetHf() public {
        _ramp();

        // carry inversion: HOLLAR debt accrues +2% → HF ~1.029 (< target 1.05)
        hollarDebt.mint(address(loop), hollarDebt.balanceOf(address(loop)) * 2 / 100);
        uint256 hfBefore = loop.healthFactor();
        assertLt(hfBefore, TARGET_HF, "HF below target after accrual");

        uint256 equityBefore = loop.totalEquity();
        loop.deLever();
        assertGt(loop.deleverDebtTarget(), 0, "de-lever target sized");

        for (uint256 i = 0; i < 200; i++) {
            if (loop.deleverDebtTarget() == 0) break;
            loop.pokeRepay();
        }

        assertEq(loop.deleverDebtTarget(), 0, "de-lever target drained");
        assertApproxEqRel(loop.healthFactor(), TARGET_HF, 0.02e18, "HF restored ~ target");
        // de-lever pays nobody: no freed credit, and equity is preserved (coll
        // −x, debt −x) up to the last poke's overshoot, which sits as idle
        // HOLLAR in the loop (folded into the next spiral cycle)
        assertEq(loop.freedOf(address(this)), 0, "no payout from deLever");
        uint256 idle8 = (hollar.balanceOf(address(loop)) - loop.reservedFreed()) / 1e10;
        assertApproxEqRel(loop.totalEquity() + idle8, equityBefore, 0.005e18, "equity preserved incl idle");

        // healthy again: a re-trigger either reverts (at/above target) or
        // re-sizes only convergence dust (HF a hair under target)
        try loop.deLever() {
            assertLt(
                loop.deleverDebtTarget(),
                hollarDebt.balanceOf(address(loop)) / 100,
                "re-trigger sized only dust"
            );
        } catch (bytes memory) {}
    }

    /// bug E regression: a finished unwinder is pruned from the credit loop
    /// (and re-registers cleanly on a new request).
    function test_unwinderPrunedAfterFullPull() public {
        _ramp();
        loop.requestUnwind(loop.sharesOf(address(this)) / 2);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        // freed ≈ requested; pull the remainder down to a zero request
        loop.pullFreed();
        // residual request dust (rounding) is fine — but once it's zero the
        // unwinder must be pruned; drive any dust out
        for (uint256 i = 0; i < 50; i++) {
            if (loop.unwindRequested(address(this)) == 0) break;
            loop.pokeRepay();
            loop.pullFreed();
        }
        assertEq(loop.unwindRequested(address(this)), 0, "request fully settled");

        // a fresh request re-registers and still gets credited
        uint256 shares = loop.sharesOf(address(this));
        assertGt(shares, 0, "half the position remains");
        loop.requestUnwind(shares);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        assertGt(loop.freedOf(address(this)), 0, "re-registered unwinder credited");
    }
}
