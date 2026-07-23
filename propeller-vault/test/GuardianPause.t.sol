// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @notice P-4: the emergency pause on both `CollateralVault` and `SubLoop` is
///         gated `onlyRole(GUARDIAN_ROLE)`, but `initialize` grants only
///         DEFAULT_ADMIN / ADMIN / UPGRADER — never GUARDIAN — and no wiring
///         script grants it either. So a freshly-deployed contract has its pause
///         wired to a role NOBODY holds: pause() reverts for everyone, and the
///         only way to enable it is a slow DEFAULT_ADMIN (governance) grant — the
///         opposite of an instant emergency halt.
///
///         These assert the intended behaviour: (1) a fresh deploy can be paused
///         by the admin from block 0 (the pause is never orphaned); (2) the admin
///         can delegate GUARDIAN_ROLE to a separate fast-path guardian (the
///         technical-committee wiring path) who can then pause. (1) fails until
///         initialize grants GUARDIAN_ROLE to the admin.
contract GuardianPauseTest is Test {
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
    SyntheticToken synth;
    SubLoop loop;
    CollateralVault vault;

    address techCommittee = address(0x7EC);

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
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (
                            address(pool),
                            address(hollar),
                            address(prime),
                            address(aPrime),
                            1.05e18,
                            1.10e18,
                            address(this)
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
                            "Propeller ETH",
                            "pETH",
                            address(eth),
                            address(pool),
                            address(loop),
                            address(0),
                            address(hollar),
                            address(synth),
                            address(aEth),
                            address(hollarDebt),
                            9800,
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );
    }

    /// A fresh deploy must be pausable from block 0 — the pause must not be wired
    /// to a role that nobody holds. `address(this)` is the admin passed to both
    /// initializers.
    function test_freshDeployIsPausableByAdmin() public {
        vault.pause();
        assertTrue(vault.paused(), "vault paused");

        loop.pause();
        assertTrue(loop.paused(), "loop paused");
    }

    /// The production fast-path: the admin (governance / DEFAULT_ADMIN) delegates
    /// GUARDIAN_ROLE to a separate guardian (the technical committee), which can
    /// then pause without any admin/governance round-trip.
    function test_adminCanDelegateGuardianToTechCommittee() public {
        vault.grantRole(vault.GUARDIAN_ROLE(), techCommittee);
        loop.grantRole(loop.GUARDIAN_ROLE(), techCommittee);

        vm.startPrank(techCommittee);
        vault.pause();
        loop.pause();
        vm.stopPrank();

        assertTrue(vault.paused(), "vault paused by tech committee");
        assertTrue(loop.paused(), "loop paused by tech committee");
    }
}
