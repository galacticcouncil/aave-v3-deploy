// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Partial Redemption Rounding — Regression Coverage
/// @notice Verifies that partial fills pay only the HOLLAR equivalent of the
///         burned HDCL — i.e. `hollarOut <= hdclBurned * rate / WAD`.
///         Pre-fix, the partial-fill branch transferred the full `available`
///         HOLLAR while burning a rounded-down `hdclToBurn`, so the redeemer
///         walked away with `available - (hdclBurned * rate / WAD)` extra wei
///         per fill.
contract PartialRedeemRoundingTest is BaseTest {
    /// @dev RedemptionPartiallyFulfilled(uint256 indexed requestId, address indexed user,
    ///                                   uint256 hollarAmount, uint256 hdclBurned)
    /// keccak256 of the canonical signature.
    bytes32 internal constant PARTIAL_FILL_TOPIC =
        keccak256("RedemptionPartiallyFulfilled(uint256,address,uint256,uint256)");

    struct PartialFill {
        uint256 requestId;
        address user;
        uint256 hollarAmount;
        uint256 hdclBurned;
    }

    /// @dev Decode all RedemptionPartiallyFulfilled events from the recorded log buffer.
    function _collectPartialFills() internal returns (PartialFill[] memory fills) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Two passes: first count, then collect.
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == PARTIAL_FILL_TOPIC) {
                count++;
            }
        }

        fills = new PartialFill[](count);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == PARTIAL_FILL_TOPIC) {
                (uint256 hollarAmount, uint256 hdclBurned) = abi.decode(
                    logs[i].data,
                    (uint256, uint256)
                );
                fills[idx++] = PartialFill({
                    requestId: uint256(logs[i].topics[1]),
                    user: address(uint160(uint256(logs[i].topics[2]))),
                    hollarAmount: hollarAmount,
                    hdclBurned: hdclBurned
                });
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   EXACT: hollarAmount == hdclBurned * rate / WAD (down to the wei)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Strict version: capture the rate at the EXACT moment of the
    ///         partial fill by stepping pokeDecentral manually and snapshotting
    ///         exchangeRate() right after the principal is added to idleHollar.
    function test_partialFill_exactPaymentAmount() public {
        // Setup that GUARANTEES a partial fill: alice's matured position
        // funds idleHollar with a known amount. Then bob deposits MUCH more
        // than that, queues his entire balance — request > idle → partial fill.
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // Bob deposits 5x more than what's in idle, ensuring his redemption
        // can only be partially fulfilled by the existing idle.
        _deposit(bob, 5 * TEN_THOUSAND_HOLLAR);

        uint256 bobHdcl = vault.balanceOf(bob);
        _requestRedeem(bob, bobHdcl);

        // Snapshot the rate at the exact moment pokeQueue will see it.
        uint256 rateAtFill = vault.exchangeRate();

        // Confirm setup: queue has work AND idle is too small for full fill
        uint256 idleAtFill = vault.idleHollar();
        uint256 fullCost = (bobHdcl * rateAtFill) / 1e18;
        require(idleAtFill < fullCost, "test setup: should require partial fill");

        vm.recordLogs();
        vault.pokeQueue();

        PartialFill[] memory fills = _collectPartialFills();
        assertGt(fills.length, 0, "expected at least one partial fill");

        // Strict invariant: hollarAmount == hdclBurned * rate / WAD (down to wei).
        // Pre-fix: hollarAmount = available, off by `(available * WAD) % rate / WAD` wei.
        for (uint256 i = 0; i < fills.length; i++) {
            uint256 expected = (fills[i].hdclBurned * rateAtFill) / 1e18;
            assertEq(
                fills[i].hollarAmount,
                expected,
                "Partial fill must pay EXACTLY hdclBurned * rate / WAD"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   EVENT: emits hollarToTransfer (not `available`)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The RedemptionPartiallyFulfilled event must report the actual
    ///         HOLLAR amount transferred, which equals `hdclBurned * rate / WAD`.
    function test_partialFill_eventReportsExactTransfer() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // Force a partial fill by overweighting bob's deposit
        _deposit(bob, 5 * TEN_THOUSAND_HOLLAR);
        _requestRedeem(bob, vault.balanceOf(bob));

        uint256 rateAtFill = vault.exchangeRate();
        uint256 bobHollarBefore = hollar.balanceOf(bob);

        vm.recordLogs();
        vault.pokeQueue();
        _claimAll(bob);

        PartialFill[] memory fills = _collectPartialFills();
        assertGt(fills.length, 0, "expected partial fill");

        uint256 totalFromEvents;
        for (uint256 i = 0; i < fills.length; i++) {
            assertEq(
                fills[i].hollarAmount,
                (fills[i].hdclBurned * rateAtFill) / 1e18,
                "Event hollarAmount must equal hdclSettled * rate / WAD"
            );
            if (fills[i].user == bob) totalFromEvents += fills[i].hollarAmount;
        }

        // The event payload (rate-locked amount) must match Bob's eventual
        // balance increase after claim.
        uint256 bobHollarAfter = hollar.balanceOf(bob);
        assertEq(
            bobHollarAfter - bobHollarBefore,
            totalFromEvents,
            "balance change must equal sum of event amounts"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ACCOUNTING SANITY: balance == idleHollar (preserved across fixes)
    // ═══════════════════════════════════════════════════════════════════════

    function test_partialFill_balanceMatchesIdleAccounting() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);
        _deposit(charlie, TEN_THOUSAND_HOLLAR / 2);

        _warpDays(61);

        _requestRedeem(alice, vault.balanceOf(alice));
        _requestRedeem(bob, vault.balanceOf(bob));
        _requestRedeem(charlie, vault.balanceOf(charlie));

        // Under pull, HOLLAR rate-locked for queue claims sits in
        // `totalReservedHollar` until users claim. The vault's HOLLAR balance
        // therefore equals idle + reserved.
        _processPositionFull(0);
        assertEq(
            hollar.balanceOf(address(vault)),
            vault.idleHollar() + vault.totalReservedHollar(),
            "after pos 0"
        );

        _processPositionFull(1);
        assertEq(
            hollar.balanceOf(address(vault)),
            vault.idleHollar() + vault.totalReservedHollar(),
            "after pos 1"
        );

        _processPositionFull(2);
        assertEq(
            hollar.balanceOf(address(vault)),
            vault.idleHollar() + vault.totalReservedHollar(),
            "after pos 2"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FUZZ: invariant holds across random scenarios
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_partialFill_fairRateInvariant(
        uint96 depositAmount,
        uint96 redeemAmount
    ) public {
        depositAmount = uint96(bound(depositAmount, 1_000e18, 50_000e18));
        _deposit(alice, depositAmount);

        _warpDays(61);

        uint256 aliceHdcl = vault.balanceOf(alice);
        if (aliceHdcl < vault.minRedeemAmount()) return;

        redeemAmount = uint96(bound(redeemAmount, vault.minRedeemAmount(), aliceHdcl));
        _requestRedeem(alice, redeemAmount);

        vm.recordLogs();
        _processPositionFull(0);

        PartialFill[] memory fills = _collectPartialFills();
        if (fills.length == 0) return;

        uint256 rateNow = vault.exchangeRate();
        for (uint256 i = 0; i < fills.length; i++) {
            // Fair-rate invariant in inequality form to tolerate small post-fill
            // rate drift: hollarAmount * WAD must be <= hdclBurned * rate.
            assertLe(
                fills[i].hollarAmount * 1e18,
                fills[i].hdclBurned * rateNow,
                "fuzz: fair-rate invariant violated"
            );
        }
    }
}

