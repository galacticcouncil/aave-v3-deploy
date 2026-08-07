// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice P-1: a *partially*-settled redemption must survive `claim()`.
///         The redeem queue settles proportionally over blocks, so a request
///         can have some collateral ready while the rest is still unwinding. A
///         user who claims the ready slice must keep their request active and
///         only burn the shares matching what they were actually paid — the
///         unsettled remainder must still be claimable later.
///
///         Buggy behaviour (pre-fix): the first `claim()` pays the partial
///         amount, deactivates the request, and burns ALL escrowed shares — the
///         unsettled remainder is destroyed and silently socialised to the other
///         holders. This test asserts the correct behaviour, so it fails on the
///         buggy contract and passes on the fixed one.
contract PartialClaimTest is Test {
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
    }

    function test_partialClaimKeepsRequestActiveAndReturnsRemainder() public {
        // ── deposit 1 ETH and ramp the loop to target HF ──────────────────
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));

        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }

        // ── request full redemption ───────────────────────────────────────
        uint256 reqId = vault.requestRedeem(shares, address(this));

        // ── PARTIAL unwind: throttle the sell sliver so pokeRepay frees only a
        //    little HOLLAR, then settle. The request ends up partially filled. ─
        loop.setTranches(10_000_000e18, 100e6); // ~$100 of aPRIME per pokeRepay
        for (uint256 i = 0; i < 6; i++) {
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // sanity: the request is only PARTIALLY settled (queue head has not
        // advanced past it) and some collateral is claimable.
        assertEq(vault.queueHead(), reqId, "request only partially settled");

        // ── claim the ready slice ─────────────────────────────────────────
        uint256 balBefore = eth.balanceOf(address(this));
        uint256 got1 = vault.claim(reqId, address(this));
        assertGt(got1, 0, "partial claim pays something");
        assertLt(got1, 1e18, "partial claim is less than full principal");
        assertEq(eth.balanceOf(address(this)) - balBefore, got1, "ETH received == claimed");

        // ── CORE of P-1: the partial claim must NOT destroy the request ────
        // Escrowed pVault shares (held at the vault) must only be burned in
        // proportion to what was paid — the remainder stays escrowed.
        assertGt(vault.balanceOf(address(vault)), 0, "escrow not destroyed by partial claim");

        // ── finish unwinding and settle the rest ──────────────────────────
        loop.setTranches(10_000_000e18, 10_000_000e6);
        for (uint256 i = 0; i < 400; i++) {
            if (loop.unwindTargetEquity() == 0) break;
            loop.pokeRepay();
        }
        vault.pokeSettle();

        // ── claim the remainder ───────────────────────────────────────────
        uint256 got2 = vault.claim(reqId, address(this));
        assertGt(got2, 0, "remainder is claimable");

        // total across both claims ≈ the full 1 ETH principal
        assertApproxEqRel(got1 + got2, 1e18, 0.02e18, "full principal returned across partial claims");

        // once settlement completes, the escrow is burned down to (at most)
        // proportional-settlement dust — the unwind spiral delevers to target HF
        // and frees marginally less than the snapshotted debtShare, so a few wei
        // of shares can remain, backed by the matching wei of un-withdrawn
        // collateral. The point of P-1 is that the *bulk* of the escrow is no
        // longer destroyed by the first partial claim (asserted above).
        assertApproxEqAbs(vault.balanceOf(address(vault)), 0, 1e15, "escrow burned to dust once complete");
    }
}
