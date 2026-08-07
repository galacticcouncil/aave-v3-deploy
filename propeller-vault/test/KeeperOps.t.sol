// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice Keeper ops: rebalance (re-lever as collateral appreciates, de-lever
///         on a drop — always toward the reserve's max LTV, read live) and
///         maintainPeg (re-top synthetic as Main debt accrues interest).
contract KeeperOpsTest is Test {
    MockERC20 eth; MockERC20 aEth; MockERC20 ethDebt;
    MockERC20 hollar; MockERC20 aHollar; MockERC20 hollarDebt;
    MockERC20 prime; MockERC20 aPrime; MockERC20 primeDebt;
    MockERC20 aSynth; MockERC20 synthDebt;
    MockPool pool; SyntheticToken synth;
    SubLoop loop; CollateralVault vault;

    uint16 constant SYNTH_LT = 9800;

    function setUp() public {
        eth = new MockERC20("ETH","ETH",18); aEth = new MockERC20("aETH","aETH",18); ethDebt = new MockERC20("dETH","dETH",18);
        hollar = new MockERC20("HOLLAR","HOLLAR",18); aHollar = new MockERC20("aHOLLAR","aHOLLAR",18); hollarDebt = new MockERC20("dHOLLAR","dHOLLAR",18);
        prime = new MockERC20("PRIME","PRIME",6); aPrime = new MockERC20("aPRIME","aPRIME",6); primeDebt = new MockERC20("dPRIME","dPRIME",6);
        synth = new SyntheticToken("Propeller Synthetic","psHOLLAR",address(this));
        aSynth = new MockERC20("aSYNTH","aSYNTH",18); synthDebt = new MockERC20("dSYNTH","dSYNTH",18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        // synth: small non-zero LTV so it can be enabled as collateral
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), SYNTH_LT, 100, 18, 1e18);

        loop = SubLoop(address(new ERC1967Proxy(address(new SubLoop()), abi.encodeCall(SubLoop.initialize,
            (address(pool),address(hollar),address(prime),address(aPrime),1.05e18,1.10e18,address(this))))));
        vault = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()), abi.encodeCall(CollateralVault.initialize,
            ("Propeller ETH","pETH",address(eth),address(pool),address(loop),address(0),address(hollar),address(synth),address(aEth),address(hollarDebt),1_000e18,address(this))))));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        // permissionless: pokeBorrow/pokeRepay/rebalance/maintainPeg need no grant
        loop.setTranches(10_000_000e18, 10_000_000e6);

        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
    }

    function _ramp() internal {
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    function test_rebalanceDownOnDrop() public {
        _ramp();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // ~2250 (75% of $3000)
        uint256 loopBefore = vault.loopShares();

        // ETH −50% → LTV blows past the band → de-lever to the max LTV
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0, "de-lever scheduled");
        assertLt(vault.loopShares(), loopBefore, "loop slice queued to unwind");

        // run the unwind spiral, then settle the de-lever repay
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // Main debt repaid toward the max LTV (ethValue 1500 × 75% = 1125)
        uint256 debtAfter = hollarDebt.balanceOf(address(vault));
        assertLt(debtAfter, debtBefore, "debt reduced");
        assertApproxEqRel(debtAfter, 1_125e18, 0.05e18, "debt ~ max LTV after de-lever");
        // INV-1 still holds
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, debtAfter, "synth still covers debt");
    }

    function test_rebalanceUpOnAppreciation() public {
        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        uint256 loopBefore = vault.loopShares();

        // ETH +50% → LTV drifts below the band → borrow more, deploy more
        pool.setPrice(address(eth), 4_500e18);
        vault.rebalance();

        assertGt(hollarDebt.balanceOf(address(vault)), debtBefore, "borrowed more on appreciation");
        assertGt(vault.loopShares(), loopBefore, "extra deployed into loop");
        // INV-1 preserved: synth still floors Main debt
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, hollarDebt.balanceOf(address(vault)), "synth still covers debt");
    }

    function test_rebalanceFollowsGovernanceLtvChange() public {
        // governance raises the ETH reserve max LTV 75% → 80%: the vault
        // auto-follows (no stored target, no admin call) on the next rebalance.
        // (small price drift so the 500bps hysteresis band is cleanly crossed:
        // ltv = 2250/3030 ≈ 74.3%, band low = 80% − 5% = 75%)
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // 2250 @ 75%
        pool.setLtv(address(eth), 8000);
        pool.setPrice(address(eth), 3_030e18);
        vault.rebalance();
        // target debt = 80% × $3030 = $2424
        assertApproxEqRel(
            hollarDebt.balanceOf(address(vault)), 2_424e18, 0.01e18, "debt re-levered to the new 80% max"
        );
        assertGt(hollarDebt.balanceOf(address(vault)), debtBefore, "borrowed the LTV delta");
    }

    function test_maintainPegOnInterestAccrual() public {
        // simulate HOLLAR debt accruing interest: +3% debt token
        uint256 extra = hollarDebt.balanceOf(address(vault)) * 3 / 100;
        hollarDebt.mint(address(vault), extra);

        // peg now broken: synth*LT < debt
        uint256 synthLtVal = aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4;
        assertLt(synthLtVal, hollarDebt.balanceOf(address(vault)), "peg broken by interest");

        vault.maintainPeg();

        // peg restored: synth*LT >= debt again
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, hollarDebt.balanceOf(address(vault)), "peg restored");
    }

    /// @notice Regression for the audit High: rebalance()'s permissionless de-lever
    ///         branch was non-idempotent — it sized off the live Main debt (unchanged
    ///         until pokeSettle applies the queued repay), so repeated calls re-fired,
    ///         inflating deleverTarget past real debt and draining the whole loop, then
    ///         bricking pokeSettle (synthBurn underflow / NO_DEBT). The fix sizes off
    ///         effective debt (live − already-queued) so extra calls are no-ops, and
    ///         pokeSettle caps the repay at live debt. Hammering rebalance must not
    ///         inflate the target, over-unwind, or freeze settlement.
    function test_rebalanceDeLeverIdempotent_noRedemptionDoS() public {
        _ramp();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // ~2250 (75% of $3000)
        uint256 loopBefore = vault.loopShares();

        // ETH −50% → over-levered → de-lever branch fires.
        pool.setPrice(address(eth), 1_500e18);

        // First rebalance queues exactly the needed de-lever.
        vault.rebalance();
        uint256 targetAfterOne = vault.deleverTarget();
        uint256 loopAfterOne = vault.loopShares();
        assertGt(targetAfterOne, 0, "de-lever scheduled");
        assertLt(loopAfterOne, loopBefore, "only the needed slice queued");

        // ATTACK: hammer the permissionless rebalance() before pokeSettle runs.
        for (uint256 i = 0; i < 25; i++) vault.rebalance();

        // Idempotent: repeated calls add nothing and never over-unwind.
        assertEq(vault.deleverTarget(), targetAfterOne, "deleverTarget not inflated by repeated calls");
        assertEq(vault.loopShares(), loopAfterOne, "loop not over-unwound by repeated calls");
        assertLe(vault.deleverTarget(), debtBefore, "target never exceeds real Main debt");

        // Settlement completes without reverting (the DoS) and de-levers to ~max LTV.
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle(); // must NOT revert

        uint256 debtAfter = hollarDebt.balanceOf(address(vault));
        assertLt(debtAfter, debtBefore, "debt reduced");
        assertApproxEqRel(debtAfter, 1_125e18, 0.05e18, "debt ~ max LTV (not driven to zero)");
        assertGe(aSynth.balanceOf(address(vault)) * SYNTH_LT / 1e4, debtAfter, "INV-1 still holds");
    }
}
