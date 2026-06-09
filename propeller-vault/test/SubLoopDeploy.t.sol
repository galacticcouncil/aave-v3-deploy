// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice Deploy-ramp flow: deposit a HOLLAR seed, then keeper pokeBorrow
///         until the loop self-ramps to the target HF (each poke borrows an
///         HF-safe tranche and router-sells it HOLLAR→aPRIME synchronously via
///         the dispatch precompile — mocked by MockDispatch etched at 0x0401).
///         Asserts the equity invariant holds throughout and HF converges.
contract SubLoopDeployTest is Test {
    MockERC20 hollar;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt; // unused debt side of PRIME reserve
    MockERC20 hollarDebt;
    MockERC20 aHollar; // unused collateral side of HOLLAR reserve
    MockPool pool;
    SubLoop loop;

    uint256 constant SEED = 1_000e18; // 1000 HOLLAR
    uint256 constant TARGET_HF = 1.05e18;

    function setUp() public {
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        prime = new MockERC20("PRIME", "PRIME", 6);
        aPrime = new MockERC20("aPRIME", "aPRIME", 6);
        primeDebt = new MockERC20("debtPRIME", "dPRIME", 6);
        hollarDebt = new MockERC20("debtHOLLAR", "dHOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);

        pool = new MockPool();
        // PRIME: LT 88%, LTV 85%, 6dp, $1
        pool.initReserve(address(prime), address(aPrime), address(primeDebt), 8800, 8500, 6, 1e18);
        // HOLLAR: borrow-only (LT 0 / LTV 0), 18dp, $1
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);

        SubLoop impl = new SubLoop();
        bytes memory init = abi.encodeCall(
            SubLoop.initialize,
            (
                address(pool),
                address(0), // dca seam unused: inline DcaDispatch
                address(hollar),
                address(prime),
                address(aPrime),
                address(hollarDebt),
                0.88e18, // PRIME LT
                TARGET_HF,
                1.10e18, // de-lever trigger
                address(this) // admin
            )
        );
        loop = SubLoop(address(new ERC1967Proxy(address(impl), init)));

        // router mock at the dispatch precompile + route ids (mainnet values)
        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 0, 10_000); // 1% slippage

        // roles + params (test is admin)
        loop.registerVault(address(this)); // VAULT_ROLE
        // permissionless: pokeBorrow needs no keeper grant
        loop.setTranches(10_000_000e18, 10_000_000e6); // big tranche → one-shot per budget
    }

    function test_deployRampReachesTargetHf() public {
        // seed the loop as a vault (the deposit levers the seed in synchronously)
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        uint256 shares = loop.deposit(SEED);
        assertEq(shares, SEED, "first-deposit shares == seed");

        // ramp: each poke borrows up to the HF floor and levers the tranche in
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        uint256 hf = loop.healthFactor();
        uint256 equity = loop.totalEquity(); // 8dp USD

        // equity invariant: stays ≈ the seed ($1000 = 1000e8) all the way
        assertApproxEqRel(equity, 1_000e8, 0.02e18, "equity ~ seed");
        // HF converged to ~target
        assertApproxEqRel(hf, TARGET_HF, 0.03e18, "HF ~ 1.05");
        // leverage: collateral ≈ seed/(1 - LT/HF) ≈ $6177
        (uint256 collBase8,,,,,) = pool.getUserAccountData(address(loop));
        assertApproxEqRel(collBase8, 6_177e8, 0.03e18, "collateral ~6.18x");
    }
}
