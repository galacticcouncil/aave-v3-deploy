// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {QueueLib} from "../../src/libraries/QueueLib.sol";

/// @title Queue Fills — strict-FIFO early settlement (QUEUE-FILLS-SPEC.md)
/// @notice Covers the unit matrix: listing lifecycle, the head-first fill
///         walk with skip semantics, partial fills, races against cancel and
///         settlement, and the accounting-neutrality invariants (a fill must
///         never move the exchange rate, totalAssets, idleHollar or
///         totalReservedHollar).
contract QueueFillsTest is BaseTest {
    uint256 internal constant BPS = 10_000;

    address public filler = makeAddr("filler");
    address public filler2 = makeAddr("filler2");
    address public operator = makeAddr("operator");
    address public guardian = makeAddr("guardian");

    struct Snap {
        uint256 rate;
        uint256 assets;
        uint256 idle;
        uint256 reserved;
        uint256 supply;
    }

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        vault.setFillsEnabled(true);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();

        hollar.mint(filler, 1_000_000e18);
        hollar.mint(filler2, 1_000_000e18);
        vm.prank(filler);
        hollar.approve(address(vault), type(uint256).max);
        vm.prank(filler2);
        hollar.approve(address(vault), type(uint256).max);
    }

    // ─── helpers ───

    function _snap() internal view returns (Snap memory s) {
        s.rate = vault.exchangeRate();
        s.assets = vault.totalAssets();
        s.idle = vault.idleHollar();
        s.reserved = vault.totalReservedHollar();
        s.supply = vault.totalSupply();
    }

    /// @dev The headline invariant: fills never touch vault accounting.
    function _assertVaultNeutral(Snap memory a, Snap memory b) internal pure {
        assertEq(b.rate, a.rate, "rate moved");
        assertEq(b.assets, a.assets, "totalAssets moved");
        assertEq(b.idle, a.idle, "idleHollar moved");
        assertEq(b.reserved, a.reserved, "totalReservedHollar moved");
        assertEq(b.supply, a.supply, "totalSupply moved");
    }

    /// @dev Expected payment for `shares` at `ask`: the exact double-floor
    ///      the walk uses.
    function _price(uint256 shares, uint256 ask) internal view returns (uint256) {
        return (((shares * vault.exchangeRate()) / 1e18) * (BPS - ask)) / BPS;
    }

    function _list(address user, uint256 requestId, uint32 askBps) internal {
        vm.prank(user);
        vault.setFillAsk(requestId, askBps);
    }

    function _ask(uint256 requestId) internal view returns (uint32 plusOne) {
        (, , , , , plusOne) = vault.getRedemptionRequest(requestId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   LISTING LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    function test_setFillAsk_listsAndReprices() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));

        vm.expectEmit(true, true, false, true, address(vault));
        emit QueueLib.FillAskSet(id, bob, 100);
        _list(bob, id, 100);
        assertEq(_ask(id), 101, "askPlusOne encodes ask+1");

        _list(bob, id, 250); // re-price
        assertEq(_ask(id), 251);
    }

    function test_setFillAsk_clearSentinel_isIdempotent() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));
        _list(bob, id, 100);

        vm.expectEmit(true, false, false, false, address(vault));
        emit QueueLib.FillAskCleared(id);
        _list(bob, id, type(uint32).max);
        assertEq(_ask(id), 0, "delisted");

        // Clearing again is a no-op, not a revert.
        _list(bob, id, type(uint32).max);
        assertEq(_ask(id), 0);
    }

    function test_setFillAsk_capAndValidation() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));

        vm.prank(bob);
        vm.expectRevert(QueueLib.AskTooHigh.selector);
        vault.setFillAsk(id, 2_001);

        vm.prank(bob);
        vm.expectRevert(QueueLib.InvalidRequestId.selector);
        vault.setFillAsk(999, 100);

        // Cancelled request: not listable.
        vm.prank(bob);
        vault.cancelRedeem(id);
        vm.prank(bob);
        vm.expectRevert(QueueLib.RequestNotActive.selector);
        vault.setFillAsk(id, 100);
    }

    function test_setFillAsk_auth() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));

        vm.prank(alice);
        vm.expectRevert(QueueLib.NotRequestOwner.selector);
        vault.setFillAsk(id, 100);

        // ERC-7540 operator may list on the controller's behalf.
        vm.prank(bob);
        vault.setOperator(operator, true);
        vm.prank(operator);
        vault.setFillAsk(id, 150);
        assertEq(_ask(id), 151);
    }

    function test_cancelRedeem_clearsAsk() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));
        _list(bob, id, 100);

        vm.expectEmit(true, false, false, false, address(vault));
        emit QueueLib.FillAskCleared(id);
        vm.prank(bob);
        vault.cancelRedeem(id);
        assertEq(_ask(id), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FULL FILL
    // ═══════════════════════════════════════════════════════════════════════

    function test_fillQueue_singleEntry_full() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 shares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, shares);
        _list(bob, id, 100); // 1%

        uint256 expectedPay = _price(shares, 100);
        Snap memory pre = _snap();
        uint256 bobHollarBefore = hollar.balanceOf(bob);
        uint256 fillerHollarBefore = hollar.balanceOf(filler);

        vm.expectEmit(true, true, false, true, address(vault));
        emit QueueLib.RequestFilled(id, bob, expectedPay, shares);
        vm.prank(filler);
        (uint256 spent, uint256 received) = vault.fillQueue(type(uint256).max, 0);

        assertEq(spent, expectedPay, "spent = quoted price");
        assertEq(received, shares, "all pending bought");
        assertEq(hollar.balanceOf(bob) - bobHollarBefore, expectedPay, "seller paid");
        assertEq(fillerHollarBefore - hollar.balanceOf(filler), expectedPay, "filler debited");
        assertEq(vault.balanceOf(filler), shares, "escrow released to filler");

        // Entry fully drained with nothing settled -> deleted, head swept.
        (, , , , bool active, ) = vault.getRedemptionRequest(id);
        assertFalse(active, "entry deleted");
        assertEq(vault.totalQueuedBil(), 0, "queue empty");
        assertEq(vault.queueHead(), vault.queueTail(), "head swept past hole");

        _assertVaultNeutral(pre, _snap());
    }

    function test_fillQueue_priceRespectsAsk() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 shares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, shares);
        _list(bob, id, 2_000); // max ask: 20%

        vm.prank(filler);
        (uint256 spent, uint256 received) = vault.fillQueue(type(uint256).max, 0);
        assertEq(received, shares);
        assertEq(spent, _price(shares, 2_000));
        // 20% below NAV, double-floored.
        assertLe(spent, (shares * vault.exchangeRate() / 1e18) * 8_000 / BPS);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PARTIAL FILL
    // ═══════════════════════════════════════════════════════════════════════

    function test_fillQueue_partial_thenCompletion() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 shares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, shares);
        _list(bob, id, 100);

        // Budget for roughly 40% of the entry.
        uint256 budget = _price(shares, 100) * 2 / 5;
        Snap memory pre = _snap();

        vm.prank(filler);
        (uint256 spent1, uint256 got1) = vault.fillQueue(budget, 0);
        assertLe(spent1, budget, "never overdraws budget");
        assertLt(got1, shares, "partial");
        assertGt(got1, 0);

        // Remainder still queued and still listed at the same ask.
        (, uint256 bilAmount, uint256 bilSettled, , bool active, ) = vault.getRedemptionRequest(id);
        assertTrue(active, "entry stays");
        assertEq(bilAmount - bilSettled, shares - got1, "pending shrank in place");
        assertEq(_ask(id), 101, "ask persists across partial fill");
        assertEq(vault.totalQueuedBil(), shares - got1);
        assertEq(vault.queueHead(), 0, "head does not pass a live entry");

        // A second filler completes it.
        vm.prank(filler2);
        (, uint256 got2) = vault.fillQueue(type(uint256).max, 0);
        assertEq(got1 + got2, shares, "aggregate demand drains the whale");
        assertEq(vault.totalQueuedBil(), 0);

        _assertVaultNeutral(pre, _snap());
    }

    function test_fillQueue_partial_exactPaymentRounding() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 shares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, shares);
        _list(bob, id, 137); // awkward ask for rounding

        uint256 budget = 3_333e18 + 7; // awkward budget
        uint256 bobBefore = hollar.balanceOf(bob);
        vm.prank(filler);
        (uint256 spent, uint256 got) = vault.fillQueue(budget, 0);

        assertLe(spent, budget, "pay <= budget always");
        assertEq(spent, _price(got, 137), "pay recomputed from shares");
        assertEq(hollar.balanceOf(bob) - bobBefore, spent);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   WALK / SKIP SEMANTICS
    // ═══════════════════════════════════════════════════════════════════════

    function test_fillQueue_strictFifo_skipsUnlistedAndUnderpriced() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);
        uint256 r0 = _requestRedeem(alice, vault.balanceOf(alice)); // unlisted
        uint256 r1 = _requestRedeem(bob, vault.balanceOf(bob));
        uint256 r2 = _requestRedeem(charlie, vault.balanceOf(charlie));
        _list(bob, r1, 50); // 0.5%
        _list(charlie, r2, 200); // 2%

        // Filler demands >= 1%: r0 unlisted (skip), r1 too cheap (skip),
        // r2 fills. Head must stay pinned before alice's live entry.
        vm.prank(filler);
        (, uint256 got) = vault.fillQueue(type(uint256).max, 100);
        (, , , , bool r2active, ) = vault.getRedemptionRequest(r2);
        assertFalse(r2active, "r2 filled");
        (, uint256 r1amount, , , bool r1active, ) = vault.getRedemptionRequest(r1);
        assertTrue(r1active, "r1 skipped (ask below filler's floor)");
        assertGt(r1amount, 0);
        (, , , , bool r0active, ) = vault.getRedemptionRequest(r0);
        assertTrue(r0active, "r0 untouched");
        assertEq(vault.queueHead(), 0, "head frozen before live head entry");
        assertGt(got, 0);

        // Second pass with no floor picks up r1; r0 (unlisted) still safe.
        vm.prank(filler);
        vault.fillQueue(type(uint256).max, 0);
        (, , , , r1active, ) = vault.getRedemptionRequest(r1);
        assertFalse(r1active, "r1 filled on second pass");
        (, , , , r0active, ) = vault.getRedemptionRequest(r0);
        assertTrue(r0active, "unlisted never fillable");
    }

    function test_fillQueue_fifoOrder_amongListed() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);
        uint256 r0 = _requestRedeem(bob, vault.balanceOf(bob));
        uint256 r1 = _requestRedeem(charlie, vault.balanceOf(charlie));
        _list(bob, r0, 100);
        _list(charlie, r1, 100);

        // Budget covers only the first entry: strictly the head seller
        // gets paid, never the later one.
        (, uint256 r0amount, , , , ) = vault.getRedemptionRequest(r0);
        // compute before prank — the helper staticcall would consume it
        uint256 budget = _price(r0amount, 100);
        vm.prank(filler);
        vault.fillQueue(budget, 0);

        (, , , , bool r0active, ) = vault.getRedemptionRequest(r0);
        (, , , , bool r1active, ) = vault.getRedemptionRequest(r1);
        assertFalse(r0active, "head filled first");
        assertTrue(r1active, "later entry untouched");
    }

    function test_fillQueue_iterationCap() public {
        _deposit(bob, 100_000e18 <= hollar.balanceOf(bob) ? 100_000e18 : hollar.balanceOf(bob));
        // 51 small requests from one controller, all listed.
        for (uint256 i; i < 51; i++) {
            uint256 id = _requestRedeem(bob, 2e18);
            _list(bob, id, 100);
        }
        vm.prank(filler);
        (, uint256 got) = vault.fillQueue(type(uint256).max, 0);
        assertEq(got, 50 * 2e18, "work cap: 50 real fills per call");

        vm.prank(filler);
        (, uint256 got2) = vault.fillQueue(type(uint256).max, 0);
        assertEq(got2, 2e18, "second call drains the tail");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   GATES + RACES
    // ═══════════════════════════════════════════════════════════════════════

    function test_fillQueue_gates() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));
        _list(bob, id, 100);

        // Kill switch.
        vm.prank(guardian);
        vault.setFillsEnabled(false);
        vm.prank(filler);
        vm.expectRevert(BILVault.FillsDisabled.selector);
        vault.fillQueue(type(uint256).max, 0);

        // Guardian cannot re-arm; admin can.
        vm.prank(guardian);
        vm.expectRevert();
        vault.setFillsEnabled(true);
        vm.prank(alice);
        vm.expectRevert(BILVault.NotAdminOrGuardian.selector);
        vault.setFillsEnabled(false);
        vm.prank(admin);
        vault.setFillsEnabled(true);

        // Pause gates fills like claims.
        vm.prank(admin);
        vault.pause();
        vm.prank(filler);
        vm.expectRevert("Pausable: paused");
        vault.fillQueue(type(uint256).max, 0);
        vm.prank(admin);
        vault.unpause();

        // Nothing listed -> NothingFilled.
        _list(bob, id, type(uint32).max);
        vm.prank(filler);
        vm.expectRevert(QueueLib.NothingFilled.selector);
        vault.fillQueue(type(uint256).max, 0);
    }

    function test_fillQueue_afterCancel_isNothingFilled() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));
        _list(bob, id, 100);
        vm.prank(bob);
        vault.cancelRedeem(id);

        vm.prank(filler);
        vm.expectRevert(QueueLib.NothingFilled.selector);
        vault.fillQueue(type(uint256).max, 0);
    }

    function test_fillQueue_selfFill_isValueNeutral() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        uint256 shares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, shares);
        _list(bob, id, 100);

        vm.prank(bob);
        hollar.approve(address(vault), type(uint256).max);
        uint256 hollarBefore = hollar.balanceOf(bob);
        vm.prank(bob);
        vault.fillQueue(type(uint256).max, 0);

        // Paid himself: HOLLAR net zero, shares back in his wallet.
        assertEq(hollar.balanceOf(bob), hollarBefore, "self-fill HOLLAR net zero");
        assertEq(vault.balanceOf(bob), shares, "shares round-tripped");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   SETTLED-SLICE ISOLATION (fill never touches settlement)
    // ═══════════════════════════════════════════════════════════════════════

    function test_fill_ignoresSettledSlice_claimSurvives() public {
        // Alice's small matured position funds a partial settlement of
        // bob's much larger request (recipe from PartialRedeemRounding).
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 5 * TEN_THOUSAND_HOLLAR);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, bobShares);

        _warpDays(61);
        _processPositionFull(0); // settles bob's entry partially

        (, uint256 amount, uint256 settled, uint256 owed, , ) = vault.getRedemptionRequest(id);
        assertGt(settled, 0, "fixture: partially settled");
        assertGt(amount - settled, 0, "fixture: pending remains");

        _list(bob, id, 100);
        Snap memory pre = _snap();
        vm.prank(filler);
        (, uint256 got) = vault.fillQueue(type(uint256).max, 0);
        assertEq(got, amount - settled, "fill bought exactly the pending tail");

        // Settled slice untouched and still claimable by BOB, not the filler.
        (, uint256 amount2, uint256 settled2, uint256 owed2, bool active, ) =
            vault.getRedemptionRequest(id);
        assertTrue(active, "entry retained for claim");
        assertEq(settled2, settled, "bilSettled untouched");
        assertEq(owed2, owed, "hollarOwed untouched");
        assertEq(amount2, settled2, "nothing pending left");
        _assertVaultNeutral(pre, _snap());

        uint256 bobHollar = hollar.balanceOf(bob);
        vm.prank(bob);
        uint256 claimed = vault.redeem(settled, bob, bob);
        assertEq(claimed, owed, "settled claim pays in full");
        assertEq(hollar.balanceOf(bob) - bobHollar, owed);
    }

    function test_fill_thenSettle_composes() public {
        // Fill part of an entry, then let settlement handle the rest —
        // both operate on `pending` and never double-count.
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, 2 * TEN_THOUSAND_HOLLAR);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 id = _requestRedeem(bob, bobShares);
        _list(bob, id, 100);

        // Partial fill first.
        uint256 third = _price(bobShares, 100) / 3;
        vm.prank(filler);
        (, uint256 filled) = vault.fillQueue(third, 0);
        (, uint256 amount, , , , ) = vault.getRedemptionRequest(id);
        assertEq(amount, bobShares - filled);

        // Then maturity-driven settlement of the remainder.
        _warpDays(61);
        _processPositionFull(0);
        _processPositionFull(1);
        (, uint256 amount3, uint256 settled3, , , ) = vault.getRedemptionRequest(id);
        assertEq(settled3, amount3, "remainder fully settled");
        assertEq(settled3, bobShares - filled, "no double-count");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ADJACENT MACHINERY UNAFFECTED
    // ═══════════════════════════════════════════════════════════════════════

    function test_fill_improvesWaitEstimateBehind() public {
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR);
        uint256 r0 = _requestRedeem(bob, vault.balanceOf(bob));
        uint256 r1 = _requestRedeem(charlie, vault.balanceOf(charlie));

        uint256 waitBefore = vault.getEstimatedWaitTime(r1);
        _list(bob, r0, 100);
        vm.prank(filler);
        vault.fillQueue(type(uint256).max, 0);

        // r0 left the queue -> charlie needs less HOLLAR ahead of him.
        assertLe(vault.getEstimatedWaitTime(r1), waitBefore, "estimate improves");
    }
}
