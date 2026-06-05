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

/// @notice CollateralVault Main-leg + the synthetic-flooring property: after a
///         deposit opens the Main position (supply ETH, borrow HOLLAR, mint+
///         supply synthetic, seed the loop), the Main HF stays >= 1 even when
///         ETH crashes ~99% — the principal is un-liquidatable. A baseline
///         (no synthetic) would be deep underwater at the same price.
contract CollateralVaultDepositTest is Test {
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
    MockDcaScheduler dca;
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;

    uint256 constant ETH_PRICE = 3_000e18; // $3000
    uint16 constant ETH_LT = 8500;
    uint16 constant ETH_LTV = 7500;
    uint16 constant SYNTH_LT = 9800;
    uint16 constant TARGET_LTV = 7400;

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
        pool.initReserve(address(eth), address(aEth), address(ethDebt), ETH_LT, ETH_LTV, 18, ETH_PRICE);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), SYNTH_LT, 0, 18, 1e18);

        dca = new MockDcaScheduler(address(pool), address(hollar), address(prime));

        // SubLoop
        SubLoop loopImpl = new SubLoop();
        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(loopImpl),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool),
                            address(dca),
                            address(hollar),
                            address(prime),
                            address(aPrime),
                            address(hollarDebt),
                            0.88e18,
                            1.05e18,
                            1.10e18,
                            address(this)
                        )
                    )
                )
            )
        );

        // CollateralVault (ETH)
        CollateralVault vaultImpl = new CollateralVault();
        vault = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Propeller ETH",
                            "pETH",
                            address(eth),
                            address(pool),
                            address(loop),
                            address(0), // swapper unused in this test
                            address(hollar),
                            address(synth),
                            address(aEth),
                            address(hollarDebt),
                            TARGET_LTV,
                            SYNTH_LT,
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );

        // wiring
        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
    }

    function test_depositOpensMainLegAndSynthFloorsHf() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));

        // Main legs opened
        assertEq(aEth.balanceOf(address(vault)), 1e18, "ETH supplied");
        uint256 debt = hollarDebt.balanceOf(address(vault));
        assertApproxEqRel(debt, 2_220e18, 0.01e18, "borrowed ~ 74% of $3000"); // $2220
        // synth sized so synth*LT >= debt (+0.5% buffer) ⇒ synth ≈ debt/0.98
        uint256 synthBal = aSynth.balanceOf(address(vault));
        uint256 synthLtValue = (synthBal * SYNTH_LT) / 1e4;
        assertGe(synthLtValue, debt, "synth*LT >= debt (floors HF)");
        assertApproxEqRel(synthLtValue, debt, 0.01e18, "synth*LT ~ debt (+buffer)");
        assertGt(vault.loopShares(), 0, "loop seeded");

        // healthy at spot
        (, , , , , uint256 hf0) = pool.getUserAccountData(address(vault));
        assertGt(hf0, 2e18, "HF high at spot");

        // crash ETH 99% → $30. Synthetic alone floors HF >= 1 → no liquidation.
        pool.setPrice(address(eth), 30e18);
        (, , , , , uint256 hfCrash) = pool.getUserAccountData(address(vault));
        assertGe(hfCrash, 1e18, "principal un-liquidatable after 99% ETH crash");

        // even at ETH = $0, the synthetic (synth*LT == debt) holds HF >= 1
        pool.setPrice(address(eth), 1); // ~0
        (, , , , , uint256 hfZero) = pool.getUserAccountData(address(vault));
        assertGe(hfZero, 1e18, "HF floored at ~1 by synthetic alone");
    }

    /// @notice Baseline: an identical ETH borrow WITHOUT the synthetic is deep
    ///         underwater at the same crashed price — what Propeller prevents.
    function test_baselineWithoutSynthIsLiquidatable() public {
        // a bare account: supply 1 ETH, borrow $2220 HOLLAR, no synthetic
        address bare = address(0xB42E);
        eth.mint(bare, 1e18);
        vm.startPrank(bare);
        eth.approve(address(pool), 1e18);
        pool.supply(address(eth), 1e18, bare, 0);
        pool.borrow(address(hollar), 2_220e18, 2, 0, bare);
        vm.stopPrank();

        pool.setPrice(address(eth), 30e18); // 99% crash
        (, , , , , uint256 hf) = pool.getUserAccountData(bare);
        assertLt(hf, 1e18, "bare position liquidatable after crash");
    }
}
