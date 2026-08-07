// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {SubLoop} from "../../src/SubLoop.sol";
import {SyntheticToken} from "../../src/SyntheticToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPool} from "../mocks/MockPool.sol";
import {DcaDispatch} from "../../src/lib/DcaDispatch.sol";
import {MockDispatch} from "../mocks/MockDispatch.sol";
import {Handler} from "./Handler.sol";

/// @notice Invariant suite. The fuzzer drives the Handler through random
///         deposit/ramp/redeem/unwind/settle/claim sequences; after every call
///         these must hold (see note-propeller-impl §8 / the invariants chat).
contract PropellerInvariantTest is Test {
    uint16 constant SYNTH_LT = 9800;

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
    Handler handler;

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
        // synth: small non-zero LTV so it can be enabled as collateral
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), SYNTH_LT, 100, 18, 1e18);

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
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );

        vm.etch(DcaDispatch.DISPATCH, address(new MockDispatch()).code);
        MockDispatch(payable(DcaDispatch.DISPATCH)).configure(
            address(pool), address(hollar), address(prime), 222, 1043
        );
        loop.configureDca(222, 43, 1043, 143, 10_000);

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
        loop.registerVault(address(vault));
        loop.setTranches(10_000_000e18, 10_000_000e6);

        handler = new Handler(vault, loop, pool, eth, prime);
        // permissionless: handler calls keeper ops without any grant

        targetContract(address(handler));
    }

    /// INV-1: principal un-liquidatable — synthetic alone covers the Main debt.
    function invariant_principalFloored() public view {
        uint256 synthLtValue = (aSynth.balanceOf(address(vault)) * SYNTH_LT) / 1e4;
        assertGe(synthLtValue, hollarDebt.balanceOf(address(vault)), "INV-1 synth*LT >= Main debt");
    }

    /// INV-3: freed equity HOLLAR is always backed by the loop's HOLLAR balance.
    function invariant_freedBacked() public view {
        assertGe(hollar.balanceOf(address(loop)), loop.reservedFreed(), "INV-3 freed backed");
    }

    /// INV-4: loop share conservation (single vault ⇒ its shares == total).
    function invariant_shareConservation() public view {
        assertEq(loop.sharesOf(address(vault)), loop.totalShares(), "INV-4 shares conserved");
    }

    /// INV-5: synthetic conservation — total supply == what the vault minted.
    function invariant_synthConserved() public view {
        assertEq(synth.totalSupply(), vault.syntheticSupplied(), "INV-5 synth conserved");
    }

    /// INV-6: redemption escrow — vault holds exactly the open-request shares.
    function invariant_escrow() public view {
        assertEq(vault.balanceOf(address(vault)), handler.ghostEscrowed(), "INV-6 escrow matches");
    }

    /// INV-7: the synthetic is never borrowed (no synth debt exists).
    function invariant_noSynthBorrow() public view {
        assertEq(synthDebt.totalSupply(), 0, "INV-7 synthetic not borrowable");
    }
}
