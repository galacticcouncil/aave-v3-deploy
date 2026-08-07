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

/// @notice bug B regression — the lark-2 misconfiguration. Aave refuses to
///         enable an LTV-0 reserve as collateral (and only auto-enables on the
///         FIRST supply), so a synth listed with LTV 0:
///           1. leaves the HF floor INERT (the "never liquidated" guarantee
///              silently doesn't hold), and
///           2. breaks `rebalance`: collBase8 misses the synth, so
///              `ethValue8 = collBase8 − synthValue8` yields a phantom LTV in
///              the hundreds of % → every call takes the de-lever branch and
///              manufactures unwind requests.
///         The remedy (small non-zero LTV listing + the vault's explicit
///         enable on the next synth supply) restores both.
contract SynthLtvZeroTest is Test {
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
        // THE BUG: synth listed with LTV 0 (live lark-2 configuration)
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), SYNTH_LT, 0, 18, 1e18);

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
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function test_ltvZeroSynthFloorInertAndRebalancePhantom() public {
        // deposit still works — the explicit enable reverts inside Aave and the
        // vault's try/catch swallows it (deposits not bricked by the listing)
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));

        // 1. floor INERT: the synth is supplied but NOT in totalCollateralBase
        (uint256 collBase8,,,,,) = pool.getUserAccountData(address(vault));
        assertApproxEqRel(collBase8, 3_000e8, 0.01e18, "collateral = ETH only, synth invisible");
        // → a crash liquidates the principal (the guarantee does NOT hold)
        pool.setPrice(address(eth), 30e18);
        (,,,,, uint256 hfCrash) = pool.getUserAccountData(address(vault));
        assertLt(hfCrash, 1e18, "floor inert: principal liquidatable");
        pool.setPrice(address(eth), 3_000e18);

        // 2. rebalance phantom: ethValue8 = (ETH only) − synthValue ≈ $693 vs
        //    $2250 debt → ~324% LTV → manufactures a de-lever every call
        uint256 loopBefore = vault.loopShares();
        vault.rebalance();
        assertGt(vault.deleverTarget(), 0, "phantom de-lever scheduled");
        assertLt(vault.loopShares(), loopBefore, "loop shares burned by phantom unwind");
    }

    function test_governanceLtvBumpPlusNextSupplyRecovers() public {
        eth.mint(address(this), 2e18);
        eth.approve(address(vault), 2e18);
        vault.deposit(1e18, address(this)); // first supply under LTV 0 → not enabled

        // remedy step 1: governance lists the synth with a small non-zero LTV.
        // NOT retroactive — the existing position is still un-flagged…
        pool.setLtv(address(synth), 100);
        (uint256 collBefore8,,,,,) = pool.getUserAccountData(address(vault));
        assertApproxEqRel(collBefore8, 3_000e8, 0.01e18, "bump alone doesn't retro-enable");

        // remedy step 2: the NEXT synth supply (any deposit / peg top-up) hits
        // the vault's explicit setUserUseReserveAsCollateral → floor engages
        vault.deposit(1e18, address(this));
        (uint256 collAfter8,,,,,) = pool.getUserAccountData(address(vault));
        assertGt(collAfter8, 10_000e8, "synth now in totalCollateralBase");

        // floor live: 99% ETH crash keeps HF ≥ 1 (principal un-liquidatable)
        pool.setPrice(address(eth), 30e18);
        (,,,,, uint256 hfCrash) = pool.getUserAccountData(address(vault));
        assertGe(hfCrash, 1e18, "floor engaged after remedy");
        pool.setPrice(address(eth), 3_000e18);

        // rebalance sane: real LTV = 4500/6000 = 75% = max → no phantom de-lever
        uint256 deleverBefore = vault.deleverTarget();
        uint256 loopBefore = vault.loopShares();
        vault.rebalance();
        assertEq(vault.deleverTarget(), deleverBefore, "no phantom de-lever");
        assertEq(vault.loopShares(), loopBefore, "no manufactured unwind");
    }
}
