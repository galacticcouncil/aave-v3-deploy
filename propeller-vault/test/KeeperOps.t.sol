// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDcaScheduler} from "./mocks/MockDcaScheduler.sol";

/// @notice Keeper ops: rebalance (re-lever as collateral appreciates) and
///         maintainPeg (re-top synthetic as Main debt accrues interest).
contract KeeperOpsTest is Test {
    MockERC20 eth; MockERC20 aEth; MockERC20 ethDebt;
    MockERC20 hollar; MockERC20 aHollar; MockERC20 hollarDebt;
    MockERC20 prime; MockERC20 aPrime; MockERC20 primeDebt;
    MockERC20 aSynth; MockERC20 synthDebt;
    MockPool pool; MockDcaScheduler dca; SyntheticToken synth;
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
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), SYNTH_LT, 0, 18, 1e18);

        dca = new MockDcaScheduler(address(pool), address(hollar), address(prime));
        loop = SubLoop(address(new ERC1967Proxy(address(new SubLoop()), abi.encodeCall(SubLoop.initialize,
            (address(pool),address(dca),address(hollar),address(prime),address(aPrime),address(hollarDebt),0.88e18,1.05e18,1.10e18,address(this))))));
        vault = CollateralVault(address(new ERC1967Proxy(address(new CollateralVault()), abi.encodeCall(CollateralVault.initialize,
            ("Propeller ETH","pETH",address(eth),address(pool),address(loop),address(0),address(hollar),address(synth),address(aEth),address(hollarDebt),7400,SYNTH_LT,1_000e18,address(this))))));

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        loop.grantRole(loop.KEEPER_ROLE(), address(this));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.grantRole(vault.KEEPER_ROLE(), address(this));

        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
    }

    function _ramp() internal {
        for (uint256 i = 0; i < 40; i++) {
            uint256 oid = loop.deployOrderId();
            if (dca.remaining(oid) > 0) dca.executeDeployFully(oid);
            loop.pokeBorrow();
        }
        if (dca.remaining(loop.deployOrderId()) > 0) dca.executeDeployFully(loop.deployOrderId());
    }

    function test_rebalanceDownOnDrop() public {
        _ramp();
        uint256 debtBefore = hollarDebt.balanceOf(address(vault)); // ~2220
        uint256 loopBefore = vault.loopShares();

        // ETH −50% → LTV blows past the band → de-lever to target
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0, "de-lever scheduled");
        assertLt(vault.loopShares(), loopBefore, "loop slice queued to unwind");

        // run the unwind spiral, then settle the de-lever repay
        uint256 uid = loop.unwindOrderId();
        for (uint256 i = 0; i < 400; i++) {
            if (dca.remaining(uid) == 0) break; // de-lever slice fully unwound
            if (aPrime.balanceOf(address(loop)) == 0) break;
            if (pool.maxWithdrawable(address(loop), address(prime)) == 0) break;
            dca.executeUnwind(uid);
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // Main debt repaid toward target (ethValue 1500 × 74% ≈ 1110)
        uint256 debtAfter = hollarDebt.balanceOf(address(vault));
        assertLt(debtAfter, debtBefore, "debt reduced");
        assertApproxEqRel(debtAfter, 1_110e18, 0.05e18, "debt ~ target LTV after de-lever");
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
}
