// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockDcaScheduler} from "./mocks/MockDcaScheduler.sol";

/// @notice Unwind flow: ramp a loop, then full-unwind via the deleveraging
///         spiral (DCA aPRIME→HOLLAR + pokeRepay). Asserts the seed equity is
///         freed back to the vault and the position fully drains, HF-safely.
contract SubLoopUnwindTest is Test {
    MockERC20 hollar;
    MockERC20 prime;
    MockERC20 aPrime;
    MockERC20 primeDebt;
    MockERC20 hollarDebt;
    MockERC20 aHollar;
    MockPool pool;
    MockDcaScheduler dca;
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

        dca = new MockDcaScheduler(address(pool), address(hollar), address(prime));

        SubLoop impl = new SubLoop();
        bytes memory init = abi.encodeCall(
            SubLoop.initialize,
            (
                address(pool),
                address(dca),
                address(hollar),
                address(prime),
                address(aPrime),
                address(hollarDebt),
                0.88e18,
                TARGET_HF,
                1.10e18,
                address(this)
            )
        );
        loop = SubLoop(address(new ERC1967Proxy(address(impl), init)));
        loop.registerVault(address(this));
        loop.grantRole(loop.KEEPER_ROLE(), address(this));
        loop.setTranches(10_000_000e18, 10_000_000e6);
    }

    function _ramp() internal {
        hollar.mint(address(this), SEED);
        hollar.approve(address(loop), SEED);
        loop.deposit(SEED);
        for (uint256 i = 0; i < 40; i++) {
            uint256 oid = loop.deployOrderId();
            if (dca.remaining(oid) > 0) dca.executeDeployFully(oid);
            loop.pokeBorrow();
        }
        uint256 last = loop.deployOrderId();
        if (dca.remaining(last) > 0) dca.executeDeployFully(last);
    }

    function test_fullUnwindFreesSeedEquity() public {
        _ramp();
        assertApproxEqRel(loop.totalEquity(), 1_000e8, 0.02e18, "ramped equity ~ seed");

        // unwind everything
        loop.requestUnwind(loop.sharesOf(address(this)));
        uint256 unwindId = loop.unwindOrderId();

        for (uint256 i = 0; i < 400; i++) {
            if (aPrime.balanceOf(address(loop)) == 0) break;
            if (pool.maxWithdrawable(address(loop), address(prime)) == 0) break;
            dca.executeUnwind(unwindId);
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
}
