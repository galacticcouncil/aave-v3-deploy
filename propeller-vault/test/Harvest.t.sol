// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {Harvester} from "../src/Harvester.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDcaScheduler} from "./mocks/MockDcaScheduler.sol";
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
    MockDcaScheduler dca;
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
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 0, 18, 1e18);

        dca = new MockDcaScheduler(address(pool), address(hollar), address(prime));
        swapper = new MockSwapper(address(pool));

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool), address(dca), address(hollar), address(prime),
                            address(aPrime), address(hollarDebt), 0.88e18, 1.05e18, 1.10e18, address(this)
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
                            address(hollarDebt), 7400, 9800, 1_000e18, address(this)
                        )
                    )
                )
            )
        );
        harvester = new Harvester(address(loop), address(prime), address(this));

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        // permissionless keeper ops: no KEEPER_ROLE grants. harvest payout pins
        // to the configured harvester; compound needs a slippage tolerance set.
        loop.setHarvester(address(harvester));
        loop.setTranches(10_000_000e18, 10_000_000e6);
        vault.setCompoundSlippageBps(100); // 1% vs oracle-fair
        harvester.addVault(address(vault));
    }

    function test_harvestCompoundsYieldIntoSharePrice() public {
        // deposit 1 ETH and ramp the loop
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        for (uint256 i = 0; i < 40; i++) {
            uint256 oid = loop.deployOrderId();
            if (dca.remaining(oid) > 0) dca.executeDeployFully(oid);
            loop.pokeBorrow();
        }
        if (dca.remaining(loop.deployOrderId()) > 0) dca.executeDeployFully(loop.deployOrderId());

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
}
