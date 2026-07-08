// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Harvester} from "../src/Harvester.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @notice Harvest: simulate PRIME yield (aPRIME accrues in the loop), then
///         harvest skims the surplus above cost basis, compounds it into the
///         ETH vault's collateral → pETH share price rises ("deposit ETH, earn
///         ETH"), and the loop equity returns to its principal basis.
contract HarvestTest is Test {
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
        // synth: LT 98%, SMALL non-zero LTV so it can be enabled as collateral
        // (the planned listing — an LTV-0 reserve can never be collateral on Aave)
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        swapper = new MockSwapper(address(pool));

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool), address(hollar), address(prime),
                            address(aPrime), 1.05e18, 1.10e18, address(this)
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
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        // permissionless keeper ops: no KEEPER_ROLE grants. harvest payout pins
        // to the configured harvester; compound needs a slippage tolerance set.
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.setCompoundSlippageBps(100); // 1% vs oracle-fair
        harvester.addVault(address(vault));
    }

    function _depositAndRamp() internal returns (uint256 shares) {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        shares = vault.deposit(1e18, address(this));
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    function test_harvestCompoundsYieldIntoSharePrice() public {
        _depositAndRamp();

        uint256 aEthBefore = aEth.balanceOf(address(vault)); // 1e18
        uint256 equityBasis = loop.totalEquity();

        // simulate PRIME yield: aPRIME accrues +5% in the loop's position
        uint256 yieldPrime = aPrime.balanceOf(address(loop)) * 5 / 100;
        aPrime.mint(address(loop), yieldPrime);
        assertGt(loop.totalEquity(), equityBasis, "yield raised equity");

        // harvest → compound into ETH collateral
        uint256[] memory minOuts = new uint256[](1);
        harvester.harvest(minOuts);

        // share price rose: vault's ETH collateral grew (yield compounded in)
        assertGt(aEth.balanceOf(address(vault)), aEthBefore, "yield compounded into pETH");
        // loop equity skimmed back to ~basis
        assertApproxEqRel(loop.totalEquity(), equityBasis, 0.01e18, "equity back to basis");
    }

    /// PRIME price appreciation (+6%) is carry like any other: harvest skims it
    /// at the ORACLE price (bug C — a $1 assumption would withdraw 6% too much
    /// PRIME and dip the loop HF below target) and compounds it into the
    /// deposit. Net effect on a 1 ETH deposit ≈ maxLtv·loopLeverage·6%.
    function test_primePriceAppreciationCompoundsToDeposit() public {
        _depositAndRamp();
        uint256 equityBasis = loop.totalEquity(); // ~2250e8 ($2250 seed)
        uint256 hfBefore = loop.healthFactor();

        pool.setPrice(address(prime), 1.06e18); // PRIME +6%

        uint256[] memory minOuts = new uint256[](1);
        harvester.harvest(minOuts);

        // surplus ≈ 6% of the levered PRIME position ≈ $833 → 0.2777 ETH @3000.
        // (0.75 LTV × ~6.17 loop leverage × 6% ≈ 27.8% of the 1 ETH deposit.)
        assertApproxEqRel(
            aEth.balanceOf(address(vault)), 1.277e18, 0.02e18, "PRIME gain compounded into pETH"
        );
        // equity back to ~basis at the NEW price (skim was oracle-sized)…
        assertApproxEqRel(loop.totalEquity(), equityBasis, 0.02e18, "equity back to basis");
        // …and the loop HF did NOT dip below where it started (bug C symptom)
        assertGe(loop.healthFactor() + 0.005e18, hfBefore, "harvest left HF at target");
    }

    /// bug A regression: harvest during an OPEN redemption must not skim the
    /// exiter's in-flight equity (shares already burned, equity still in the
    /// loop) — only true carry above basis + in-flight unwinds.
    function test_harvestSkipsInFlightUnwindEquity() public {
        uint256 shares = _depositAndRamp();
        uint256 equity0 = loop.totalEquity(); // ~2250e8

        // open a redemption for HALF the position → ~half the equity in flight
        uint256 reqId = vault.requestRedeem(shares / 2, address(this));
        uint256 inFlight = loop.unwindTargetEquity();
        assertApproxEqRel(inFlight, uint256(equity0) * 1e10 / 2, 0.01e18, "half equity in flight");

        // accrue 1% PRIME yield — the only true carry
        uint256 yieldPrime = aPrime.balanceOf(address(loop)) / 100;
        aPrime.mint(address(loop), yieldPrime);

        // harvest mid-redemption: skims ONLY the yield, not the exiter's slice
        uint256 surplusPrime = loop.harvest();
        assertApproxEqRel(surplusPrime, yieldPrime, 0.02e18, "skimmed only the carry");
        assertEq(loop.unwindTargetEquity(), inFlight, "in-flight equity untouched");

        // the exiter still settles to ~their full half ETH
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();
        uint256 got = vault.claim(reqId, address(this));
        assertApproxEqRel(got, 0.5e18, 0.02e18, "exiter principal intact");
    }
}
