// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SubLoop} from "../src/SubLoop.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {DcaDispatch} from "../src/lib/DcaDispatch.sol";
import {MockDispatch} from "./mocks/MockDispatch.sol";

/// @notice Interference between the permissionless `rebalance()` de-lever and the
///         FIFO redemption queue.
///
///         `adminUnwind` sizes its de-lever as `debt - totalQueuedDebt` precisely so
///         it never repays debt that a queued redeemer's snapshot still expects to
///         repay itself. `rebalance()`'s de-lever branch has no such subtraction — it
///         sizes off the full live debt, which INCLUDES every queued redeemer's
///         `debtShare`. When it does, `pokeSettle` spends the shared freed-HOLLAR
///         bucket repaying that debt (and burning the matching synthetic) ahead of
///         the queue, so the queued request's `repaid` can never reach its
///         `debtShare`: `queueHead` never advances and the collateral is never fully
///         released.
contract DeleverQueueInterferenceTest is Test {
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
        // PRIME is listed in isolation mode on the live market, so a plain supply
        // never auto-enables it as collateral — only pokeBorrow's explicit call does.
        pool.setIsolationMode(address(prime), true);

        loop = SubLoop(
            address(
                new ERC1967Proxy(
                    address(new SubLoop()),
                    abi.encodeCall(
                        SubLoop.initialize,
                        (address(pool), address(hollar), address(prime), address(aPrime), 1.05e18, 1.10e18, address(this))
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

    function _depositAndRamp() internal {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this));
        for (uint256 i = 0; i < 40; i++) {
            loop.pokeBorrow();
        }
    }

    /// @dev Returns the number of spiral rounds actually consumed. The unwind
    ///      spiral converges GEOMETRICALLY — each `pokeRepay` may only sell the
    ///      sliver that keeps HF above STEP_HF_FLOOR — so the tail of a redemption
    ///      takes many more keeper calls than the bulk of it.
    function _grind(uint256 budget) internal returns (uint256 rounds) {
        for (rounds = 0; rounds < budget; rounds++) {
            if (loop.unwindTargetEquity() == 0 && loop.deleverDebtTarget() == 0) break;
            try loop.pokeRepay() {}
            catch (bytes memory err) {
                console2.log("pokeRepay REVERTED at round", rounds);
                console2.logBytes(err);
                break;
            }
            try vault.pokeSettle() {}
            catch (bytes memory err) {
                console2.log("pokeSettle REVERTED at round", rounds);
                console2.logBytes(err);
                break;
            }
        }
        try vault.pokeSettle() {} catch {}
    }

    function _req(uint256 id)
        internal
        view
        returns (uint256 shares, uint256 collateralOwed, uint256 debtShare, uint256 repaid, bool active)
    {
        (, shares, collateralOwed, debtShare,, repaid,,, active) = vault.redemptions(id);
    }

    /// REGRESSION. A queued redemption plus a permissionless de-lever: `rebalance`
    /// used to size its de-lever off the FULL live debt, queued `debtShare`
    /// included, so `pokeSettle` repaid the redeemer's own slice out from under
    /// them (and burned the matching synthetic off the whole book, which can
    /// underflow `syntheticSupplied` once `target/debt + queuedFraction > 1`).
    ///
    /// Pre-fix on this scenario: deleverTarget 1125e18 against 225e18 of non-queued
    /// debt — a 5x over-size that repaid 900 HOLLAR of the redeemer's own debt.
    function test_rebalanceDeleverIsCappedAtNonQueuedDebt() public {
        _depositAndRamp();

        uint256 debtBefore = hollarDebt.balanceOf(address(vault));
        uint256 synthBefore = vault.syntheticSupplied();
        assertGt(debtBefore, 0, "position open");

        // Redeem 90% of the supply. The snapshot claims 90% of Main debt.
        uint256 shares = (vault.balanceOf(address(this)) * 90) / 100;
        uint256 id = vault.requestRedeem(shares, address(this));
        (, , uint256 debtShare, , ) = _req(id);
        uint256 queuedDebt = vault.totalQueuedDebt();
        assertEq(debtShare, queuedDebt, "queue holds the whole snapshot");

        // Collateral halves -> the position is over-levered on the REAL collateral,
        // so the permissionless de-lever branch fires.
        pool.setPrice(address(eth), 1_500e18);
        vault.rebalance();

        uint256 target = vault.deleverTarget();
        uint256 nonQueuedDebt = debtBefore > queuedDebt ? debtBefore - queuedDebt : 0;
        console2.log("live debt       ", debtBefore);
        console2.log("queued debt     ", queuedDebt);
        console2.log("non-queued debt ", nonQueuedDebt);
        console2.log("deleverTarget   ", target);

        assertLe(target, nonQueuedDebt, "de-lever must never exceed the NON-queued Main debt");
        assertGt(target, 0, "but it must still de-lever the non-queued portion");

        // The de-lever's synthetic burn is proportional to the debt it repays, so
        // capping the debt caps the burn: the queued request's pre-burn synthShare
        // snapshot stays covered by the remaining syntheticSupplied.
        _grind(600);
        assertLe(
            target,
            synthBefore,
            "sanity: burn basis bounded"
        );
        (, , uint256 ds, uint256 repaid, ) = _req(id);
        assertGe(repaid * 10_000 / ds, 9_999, "redeemer settles to >=99.99% of its snapshot");
    }

    /// REGRESSION. The unwind spiral hits a HARD STALL, not slow convergence:
    /// `pokeRepay` may only sell the sliver that keeps HF above STEP_HF_FLOOR
    /// (1.02), and once that sliver floors to zero in 6dp aPRIME the budget can
    /// only shrink — the position never moves again. Measured with a FRICTIONLESS
    /// mock, so this is pure 8dp/6dp truncation; real slippage and negative carry
    /// only widen it. Pre-fix, state was byte-identical at 2,000 and 6,000 rounds
    /// with `unwindTargetEquity` pinned at 6.71e12 wei.
    ///
    /// Left open, `r.repaid` never reaches `r.debtShare`: `queueHead` never advances
    /// past the head request, every request behind it is blocked forever, the
    /// redeemer's last sliver of collateral is never released, and
    /// `setYieldSource`'s drain guard can never be satisfied.
    function test_unwindSpiralTailIsRetiredNotStalled() public {
        _depositAndRamp();
        uint256 shares = vault.balanceOf(address(this));
        uint256 id = vault.requestRedeem(shares, address(this));

        uint256 rounds = _grind(2_000);
        (, , uint256 ds, uint256 repaid, bool active) = _req(id);

        console2.log("spiral rounds      ", rounds);
        console2.log("repaid / debtShare ", repaid, ds);
        console2.log("pendingUnwindOf    ", loop.pendingUnwindOf(address(vault)));
        console2.log("loop aPRIME left   ", aPrime.balanceOf(address(loop)));
        console2.log("unwindTargetEquity ", loop.unwindTargetEquity());
        console2.log("queueHead / tail   ", vault.queueHead(), vault.queueTail());

        assertLt(rounds, 2_000, "spiral must terminate, not burn the whole budget");
        assertEq(loop.unwindTargetEquity(), 0, "unrealizable remainder written off");
        assertEq(loop.pendingUnwindOf(address(vault)), 0, "vault has no outstanding claim");
        assertGe(repaid, ds, "request reaches its (snapped-down) debtShare");
        assertEq(vault.queueHead(), vault.queueTail(), "FIFO head retires");
        assertTrue(active, "still claimable until the owner claims");

        // The redeemer gets essentially all of it, and claim closes the request out.
        uint256 before = eth.balanceOf(address(this));
        vault.claim(id, address(this));
        assertGt(eth.balanceOf(address(this)) - before, 0.99e18, "collateral returned");
        (, , , , bool stillActive) = _req(id);
        assertFalse(stillActive, "request closed on final claim");
    }

    /// `SubLoop.requestUnwind` derives its target from live loop equity with no
    /// zero-check, while the vault has already escrowed shares and enqueued a
    /// non-zero `debtShare`. Redeeming before the loop is ramped (aPRIME held but
    /// never flagged as collateral, so `totalEquity() == 0`) therefore registers a
    /// ZERO unwind target: nothing will ever be freed for that request.
    ///
    /// Observed live on lark-4 (2026-07-31): a pre-ramp redeem left an orphaned
    /// request #0 that only later settled out of the commingled freed bucket.
    function test_requestRedeemBeforeRampRecordsZeroUnwindTarget() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this)); // NO pokeBorrow ramp

        assertGt(vault.loopShares(), 0, "vault holds loop shares");
        assertEq(loop.totalEquity(), 0, "un-ramped loop: aPRIME not flagged as collateral");

        uint256 shares = vault.balanceOf(address(this)) / 2;

        // Fail closed rather than escrow shares against a target of zero.
        vm.expectRevert(CollateralVault.NoLoopEquity.selector);
        vault.requestRedeem(shares, address(this));

        // pokeBorrow is permissionless — ramp and the same call now succeeds with a
        // real, fundable unwind target.
        loop.pokeBorrow();
        assertGt(loop.totalEquity(), 0, "loop has equity once ramped");

        uint256 id = vault.requestRedeem(shares, address(this));
        (, , uint256 debtShare, , bool active) = _req(id);
        assertGt(debtShare, 0, "vault enqueued a real debt slice");
        assertTrue(active, "request is live");
        assertGt(
            loop.pendingUnwindOf(address(vault)),
            0,
            "SubLoop records a non-zero unwind target for a live request"
        );
    }

    /// The guard is on the VAULT, not the loop: `SubLoop.requestUnwind` must stay
    /// able to burn shares and record a (possibly zero) target unconditionally, so
    /// the seam keeps working for any future caller that has no user to strand.
    function test_subLoopRequestUnwindStillPermissiveAtZeroEquity() public {
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        vault.deposit(1e18, address(this)); // NO ramp -> totalEquity() == 0

        assertEq(loop.totalEquity(), 0, "un-ramped loop reports zero equity");
        assertGt(loop.sharesOf(address(vault)), 0, "but the vault holds loop shares");

        // The loop itself does not reject a zero-equity unwind — only the vault does.
        uint256 held = loop.sharesOf(address(vault));
        vm.prank(address(vault));
        loop.requestUnwind(held);
        assertEq(loop.sharesOf(address(vault)), 0, "source burned the shares");
    }
}
