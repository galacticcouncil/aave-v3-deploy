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

/// @notice The full LIVE topology end-to-end: TWO collateral vaults (ETH at
///         75% max LTV, tBTC at 80% — the lark-2 reserve configs) share one SubLoop,
///         one SyntheticToken and one Harvester. Both deposit, the shared loop
///         ramps, PRIME yield accrues, and ONE harvest skims the carry, splits
///         it pro-rata by loop shares and swaps each cut back into THAT vault's
///         own collateral — "deposit ETH, earn ETH; deposit tBTC, earn tBTC".
///         Then the ETH depositor exits with principal + compounded yield while
///         the tBTC vault is completely untouched (cross-vault isolation).
contract MultiVaultFlowTest is Test {
    MockERC20 eth; MockERC20 aEth; MockERC20 ethDebt;
    MockERC20 tbtc; MockERC20 aTbtc; MockERC20 tbtcDebt;
    MockERC20 hollar; MockERC20 aHollar; MockERC20 hollarDebt;
    MockERC20 prime; MockERC20 aPrime; MockERC20 primeDebt;
    MockERC20 aSynth; MockERC20 synthDebt;

    MockPool pool;
    MockSwapper swapper;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault ethVault;
    CollateralVault tbtcVault;
    Harvester harvester;

    address constant ETH_USER = address(0xE0);
    address constant BTC_USER = address(0xB0);

    function setUp() public {
        eth = new MockERC20("ETH", "ETH", 18);
        aEth = new MockERC20("aETH", "aETH", 18);
        ethDebt = new MockERC20("dETH", "dETH", 18);
        tbtc = new MockERC20("tBTC", "tBTC", 18);
        aTbtc = new MockERC20("atBTC", "atBTC", 18);
        tbtcDebt = new MockERC20("dtBTC", "dtBTC", 18);
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
        // lark-2 reserve configs: ETH LT85/LTV75 @$3000, tBTC LT85/LTV80 @$60000
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(tbtc), address(aTbtc), address(tbtcDebt), 8500, 8000, 18, 60_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
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
        ethVault = _deployVault("Propeller ETH", "pETH", address(eth), address(aEth));
        tbtcVault = _deployVault("Propeller tBTC", "ptBTC", address(tbtc), address(aTbtc));
        harvester = new Harvester(address(loop), address(prime), address(this));

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 0, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(ethVault));
        synth.grantRole(synth.MINTER_ROLE(), address(tbtcVault));
        loop.registerVault(address(ethVault));
        loop.registerVault(address(tbtcVault));
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        ethVault.setCompoundSlippageBps(100);
        tbtcVault.setCompoundSlippageBps(100);
        harvester.addVault(address(ethVault));
        harvester.addVault(address(tbtcVault));
    }

    function _deployVault(string memory n, string memory s, address coll, address aTok)
        internal
        returns (CollateralVault v)
    {
        v = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            n, s, coll, address(pool), address(loop), address(swapper),
                            address(hollar), address(synth), aTok, address(hollarDebt),
                            9800, 1_000e18, address(this)
                        )
                    )
                )
            )
        );
    }

    function test_fullFlowTwoVaultsYieldInKind() public {
        // ── 1. supply: 1 ETH ($3000 → $2250 @75%) + 0.1 tBTC ($6000 → $4800 @80%)
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        uint256 ethShares = ethVault.deposit(1e18, ETH_USER);
        vm.stopPrank();

        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        vm.stopPrank();

        // loop seeded with both Main borrows: $2250 + $4800 = $7050
        assertApproxEqRel(loop.totalEquity(), 7_050e8, 0.01e18, "shared loop seeded by both");

        // ── 2. loop: ramp the SHARED position to target HF
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
        assertApproxEqRel(loop.healthFactor(), 1.05e18, 0.03e18, "shared loop at target HF");
        uint256 basis = loop.totalEquity();

        // ── 3. earn: PRIME yield accrues +5% on the levered position (~$2177)
        uint256 yieldPrime = aPrime.balanceOf(address(loop)) * 5 / 100;
        aPrime.mint(address(loop), yieldPrime);

        // ── 4. harvest: ONE call skims the carry, splits pro-rata by loop
        //      shares, and swaps each cut back into THAT vault's collateral
        uint256[] memory minOuts = new uint256[](2);
        harvester.harvest(minOuts);

        uint256 ethGain = aEth.balanceOf(address(ethVault)) - 1e18; // ETH units
        uint256 tbtcGain = aTbtc.balanceOf(address(tbtcVault)) - 0.1e18; // tBTC units
        assertGt(ethGain, 0, "ETH vault earned ETH");
        assertGt(tbtcGain, 0, "tBTC vault earned tBTC");

        // in-kind: nothing cross-contaminated
        assertEq(aTbtc.balanceOf(address(ethVault)), 0, "no tBTC in the ETH vault");
        assertEq(aEth.balanceOf(address(tbtcVault)), 0, "no ETH in the tBTC vault");

        // pro-rata by loop shares: USD gains split 2250 : 4800
        uint256 ethGainUsd = ethGain * 3_000 / 1e10; // 8dp USD
        uint256 tbtcGainUsd = tbtcGain * 60_000 / 1e10; // 8dp USD
        assertApproxEqRel(
            ethGainUsd * 4_800, tbtcGainUsd * 2_250, 0.01e18, "carry split pro-rata by loop shares"
        );
        // and the loop is skimmed back to its principal basis
        assertApproxEqRel(loop.totalEquity(), basis, 0.01e18, "loop equity back to basis");

        // yield-on-deposit tracks the vault's OWN max LTV: tBTC (80%) beats ETH (75%)
        // ethGain/1.0 vs tbtcGain/0.1 — both ≈ ltv·leverage·5%, ratio 75:80
        assertGt(tbtcGain * 10, ethGain, "tBTC %-yield > ETH %-yield (higher LTV)");
        assertGt(ethVault.exchangeRate(), 1e18, "pETH share price rose");
        assertGt(tbtcVault.exchangeRate(), 1e18, "ptBTC share price rose");

        // ── 5. exit: ETH user redeems everything — principal + compounded yield
        uint256 tbtcVaultCollBefore = aTbtc.balanceOf(address(tbtcVault));
        uint256 tbtcLoopSharesBefore = tbtcVault.loopShares();

        vm.prank(ETH_USER);
        uint256 reqId = ethVault.requestRedeem(ethShares, ETH_USER);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        ethVault.pokeSettle();
        vm.prank(ETH_USER);
        uint256 got = ethVault.claim(reqId, ETH_USER);

        // got back MORE ETH than deposited (principal + ~23% compounded carry)
        assertGt(got, 1e18, "exit returns principal + yield, in ETH");
        assertApproxEqRel(got, 1e18 + ethGain, 0.02e18, "exit ~ principal + compounded gain");

        // cross-vault isolation: the tBTC position is untouched by the ETH exit
        assertEq(aTbtc.balanceOf(address(tbtcVault)), tbtcVaultCollBefore, "tBTC collateral untouched");
        assertEq(tbtcVault.loopShares(), tbtcLoopSharesBefore, "tBTC loop shares untouched");
        assertGt(loop.totalEquity(), 0, "tBTC slice still in the loop");
    }

    /// NET carry with the HOLLAR borrow rate modeled: one year at 6.5% PRIME
    /// supply vs 4.4% HOLLAR borrow, accrued on ALL debt legs (the loop's debt
    /// AND each vault's Main debt). harvest must skim only
    /// gross − loop borrow cost, and the economic net per deposit (compounded
    /// gain minus the vault's own accrued Main interest) must land on the model
    ///   net ≈ mainLtv · loopLeverage · (primeYield − borrowRate)
    /// — the number the UI quotes. tBTC's % beats ETH's (80% vs 75% LTV).
    function test_netCarryAfterHollarBorrowCost() public {
        uint256 PRIME_APY_BPS = 650; // 6.5% PRIME supply
        uint256 BORROW_APY_BPS = 440; // 4.4% HOLLAR variable borrow

        // supply + ramp (same as the flow test)
        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        ethVault.deposit(1e18, ETH_USER);
        vm.stopPrank();
        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        vm.stopPrank();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        (uint256 loopColl8, uint256 loopDebt8,,,,) = pool.getUserAccountData(address(loop));
        uint256 loopLevWad = (loopColl8 * 1e18) / (loopColl8 - loopDebt8); // ~6.17e18

        // ── one year passes: yield on the PRIME leg, interest on EVERY debt leg
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) * PRIME_APY_BPS / 10_000);
        hollarDebt.mint(address(loop), hollarDebt.balanceOf(address(loop)) * BORROW_APY_BPS / 10_000);
        uint256 ethMainInt = hollarDebt.balanceOf(address(ethVault)) * BORROW_APY_BPS / 10_000;
        uint256 tbtcMainInt = hollarDebt.balanceOf(address(tbtcVault)) * BORROW_APY_BPS / 10_000;
        hollarDebt.mint(address(ethVault), ethMainInt);
        hollarDebt.mint(address(tbtcVault), tbtcMainInt);

        // peg upkeep: synth re-tops to cover the accrued Main debt (INV-1)
        ethVault.maintainPeg();
        tbtcVault.maintainPeg();
        assertGe(
            aSynth.balanceOf(address(ethVault)) * 9800 / 1e4,
            hollarDebt.balanceOf(address(ethVault)),
            "synth covers accrued ETH Main debt"
        );

        // ── harvest skims gross PRIME yield MINUS the loop's borrow cost
        uint256 expectedLoopNet8 =
            (loopColl8 * PRIME_APY_BPS - loopDebt8 * BORROW_APY_BPS) / 10_000;
        uint256 surplusPrime = loop.harvest(); // 6dp, $1 → 8dp USD = ×100
        assertApproxEqRel(surplusPrime * 100, expectedLoopNet8, 0.01e18, "skim = gross - loop borrow cost");

        // distribute + compound into each collateral
        uint256[] memory minOuts = new uint256[](2);
        harvester.harvest(minOuts);

        // ── economic net per deposit = compounded gain − own Main interest,
        //    must match mainLtv·loopLeverage·spread
        uint256 spreadBps = PRIME_APY_BPS - BORROW_APY_BPS; // 210
        // ETH: deposit $3000 at 75%
        uint256 ethGainUsd8 = (aEth.balanceOf(address(ethVault)) - 1e18) * 3_000 / 1e10;
        uint256 ethNetUsd8 = ethGainUsd8 - ethMainInt / 1e10;
        uint256 ethModel8 = (3_000e8 * 7_500 / 10_000) * loopLevWad / 1e18 * spreadBps / 10_000;
        assertApproxEqRel(ethNetUsd8, ethModel8, 0.02e18, "ETH net = ltv*leverage*spread");
        // tBTC: deposit $6000 at 80%
        uint256 tbtcGainUsd8 = (aTbtc.balanceOf(address(tbtcVault)) - 0.1e18) * 60_000 / 1e10;
        uint256 tbtcNetUsd8 = tbtcGainUsd8 - tbtcMainInt / 1e10;
        uint256 tbtcModel8 = (6_000e8 * 8_000 / 10_000) * loopLevWad / 1e18 * spreadBps / 10_000;
        assertApproxEqRel(tbtcNetUsd8, tbtcModel8, 0.02e18, "tBTC net = ltv*leverage*spread");

        // tBTC's net %-yield > ETH's (higher LTV), both ≈ ltv·6.17·2.1%
        // (ETH ~9.7%, tBTC ~10.4% at these rates)
        assertGt(tbtcNetUsd8 * 3_000e8 / 6_000e8, ethNetUsd8, "tBTC net %-yield > ETH net %-yield");
    }

    /// Swap COSTS modeled: 5 bps on each loop router leg (stableswap pool-143
    /// fee/impact — paid on the FULL ~6.2× levered volume at ramp and unwind)
    /// and 30 bps on the compound swap (PRIME → collateral via the router).
    /// The fee holes have to show up exactly where they belong:
    ///   - ramp:    equity lands BELOW the seed basis (fee × levered volume),
    ///              and the first carry refills that hole before harvest skims
    ///   - compound: realized gain < frictionless gain, > 95% of it
    ///   - exit:     settles slightly under the snapshot, still > principal
    function test_swapCostsReduceRealizedYield() public {
        MockDispatch(payable(DcaDispatch.DISPATCH)).setFeeBps(5); // loop legs
        swapper.setHaircut(30); // compound swap (< the 100 bps oracle floor)

        eth.mint(ETH_USER, 1e18);
        vm.startPrank(ETH_USER);
        eth.approve(address(ethVault), 1e18);
        uint256 ethShares = ethVault.deposit(1e18, ETH_USER);
        vm.stopPrank();
        tbtc.mint(BTC_USER, 0.1e18);
        vm.startPrank(BTC_USER);
        tbtc.approve(address(tbtcVault), 0.1e18);
        tbtcVault.deposit(0.1e18, BTC_USER);
        vm.stopPrank();
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        // ── ramp cost: 5 bps over ~$43.5k swapped ≈ $22 → equity < $7050 seed
        uint256 equity = loop.totalEquity();
        assertLt(equity, 7_050e8, "ramp fees dent the equity");
        assertGt(equity, 7_010e8, "...by roughly fee x levered volume (~$22)");

        // harvest with equity under basis is a no-op — carry must refill the
        // fee hole first (the cost is borne by yield, not by other vaults)
        assertEq(loop.harvest(), 0, "no skim below cost basis");

        // ── 5% PRIME yield, then harvest+compound (30 bps haircut on the swap)
        aPrime.mint(address(loop), aPrime.balanceOf(address(loop)) * 5 / 100);
        uint256[] memory minOuts = new uint256[](2);
        harvester.harvest(minOuts);

        uint256 ethGain = aEth.balanceOf(address(ethVault)) - 1e18;
        // frictionless gain was ~0.2316 ETH; with the ramp-fee hole (~1% of
        // the carry) and the 30 bps compound haircut it lands just below
        assertLt(ethGain, 0.2316e18, "swap costs reduce the realized gain");
        assertGt(ethGain, (0.2316e18 * 95) / 100, "costs stay ~1-2%, not material");

        // ── exit pays the unwind leg's fee: settles a hair under the snapshot,
        //    but still well above the deposited principal
        vm.prank(ETH_USER);
        uint256 reqId = ethVault.requestRedeem(ethShares, ETH_USER);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        ethVault.pokeSettle();
        vm.prank(ETH_USER);
        uint256 got = ethVault.claim(reqId, ETH_USER);
        assertGt(got, 1e18, "principal + yield survive the round-trip costs");
        assertLt(got, 1e18 + ethGain, "exit pays the unwind fee");
        assertGt(got, ((1e18 + ethGain) * 99) / 100, "unwind fee ~6bps x leverage");
    }
}
