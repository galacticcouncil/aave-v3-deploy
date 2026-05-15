// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Principal Mismatch Event — Regression Coverage
/// @notice Verifies the vault emits PrincipalMismatch when Decentral's payout
///         differs from the recorded position principal. The event makes
///         silently-socialized losses observable so operators can monitor for
///         integration drift (rounding, exit fees, surprise bonus payouts).
contract PrincipalMismatchTest is BaseTest {
    /// @dev keccak256("PrincipalMismatch(uint256,uint256,uint256,uint256,int256)")
    bytes32 internal constant MISMATCH_TOPIC =
        keccak256("PrincipalMismatch(uint256,uint256,uint256,uint256,int256)");

    struct Mismatch {
        uint256 positionIndex;
        uint256 tokenId;
        uint256 expected;
        uint256 received;
        int256 delta;
    }

    function _collectMismatches() internal returns (Mismatch[] memory mismatches) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == MISMATCH_TOPIC) {
                count++;
            }
        }

        mismatches = new Mismatch[](count);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == MISMATCH_TOPIC) {
                (uint256 expected, uint256 received, int256 delta) = abi.decode(
                    logs[i].data,
                    (uint256, uint256, int256)
                );
                mismatches[idx++] = Mismatch({
                    positionIndex: uint256(logs[i].topics[1]),
                    tokenId: uint256(logs[i].topics[2]),
                    expected: expected,
                    received: received,
                    delta: delta
                });
            }
        }
    }

    /// @dev Bring position 0 up through to PrincipalWithdrawalRequested with the
    /// approval already in place — caller can then warp + pokeDecentral to trigger
    /// the principal redemption with whatever payoutDelta has been set.
    function _readyForPrincipalRedemption() internal returns (uint256 tokenId) {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);

        vault.pokeDecentral(0); // Active → YWR
        (tokenId,,,,,) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(0); // YWR → YC → PWR cascade
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   NO MISMATCH (common case): event must NOT fire
    // ═══════════════════════════════════════════════════════════════════════

    function test_principalRedemption_exactPayout_noEvent() public {
        uint256 tokenId = _readyForPrincipalRedemption();

        vm.recordLogs();
        vault.pokeDecentral(0);

        Mismatch[] memory ms = _collectMismatches();
        assertEq(ms.length, 0, "no PrincipalMismatch event when payout is exact");

        // Sanity: position is Redeemed
        (,,,,, uint8 state) = vault.getPosition(0);
        assertEq(state, 4, "position redeemed");
        tokenId; // suppress unused
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   UNDERPAYMENT: Decentral pays less than principal
    // ═══════════════════════════════════════════════════════════════════════

    function test_principalRedemption_shortfall_emitsEvent() public {
        uint256 tokenId = _readyForPrincipalRedemption();

        // Inject a 100-wei shortfall: Decentral pays principal - 100 wei
        pool.setPayoutDelta(tokenId, -100);

        vm.recordLogs();
        vault.pokeDecentral(0);

        Mismatch[] memory ms = _collectMismatches();
        assertEq(ms.length, 1, "exactly one PrincipalMismatch event");

        assertEq(ms[0].positionIndex, 0, "positionIndex");
        assertEq(ms[0].tokenId, tokenId, "tokenId");
        assertEq(ms[0].expected, TEN_THOUSAND_HOLLAR, "expected = original principal");
        assertEq(ms[0].received, TEN_THOUSAND_HOLLAR - 100, "received = principal - 100");
        assertEq(ms[0].delta, int256(-100), "delta = -100");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   OVERPAYMENT: Decentral pays more than principal
    // ═══════════════════════════════════════════════════════════════════════

    function test_principalRedemption_bonus_emitsEvent() public {
        uint256 tokenId = _readyForPrincipalRedemption();

        // Inject a 250-wei bonus
        pool.setPayoutDelta(tokenId, 250);
        // Mock pool needs to actually have 250 extra HOLLAR to send;
        // BaseTest's setUp funds pool with 10M HOLLAR which is plenty.

        vm.recordLogs();
        vault.pokeDecentral(0);

        Mismatch[] memory ms = _collectMismatches();
        assertEq(ms.length, 1, "one mismatch event for bonus payout");
        assertEq(ms[0].expected, TEN_THOUSAND_HOLLAR, "expected = original principal");
        assertEq(ms[0].received, TEN_THOUSAND_HOLLAR + 250, "received = principal + 250");
        assertEq(ms[0].delta, int256(250), "delta = +250");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ACCOUNTING: shortfall is socialized through the rate; bonus lifts it
    // ═══════════════════════════════════════════════════════════════════════

    function test_principalRedemption_shortfallReducesExchangeRate() public {
        uint256 tokenId = _readyForPrincipalRedemption();
        pool.setPayoutDelta(tokenId, -1_000e18); // 1000 HOLLAR shortfall

        uint256 rateBefore = vault.exchangeRate();
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        // Rate should drop because the vault is short 1000 HOLLAR
        assertLt(rateAfter, rateBefore, "rate drops on shortfall");
    }

    function test_principalRedemption_bonusIncreasesExchangeRate() public {
        uint256 tokenId = _readyForPrincipalRedemption();
        pool.setPayoutDelta(tokenId, 500e18); // 500 HOLLAR bonus

        uint256 rateBefore = vault.exchangeRate();
        vault.pokeDecentral(0);
        uint256 rateAfter = vault.exchangeRate();

        // Rate should rise because the vault got 500 extra HOLLAR
        assertGt(rateAfter, rateBefore, "rate rises on bonus");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   EVENT INTEGRITY: PositionRedeemed still fires alongside Mismatch
    // ═══════════════════════════════════════════════════════════════════════

    function test_principalRedemption_bothEventsFire() public {
        uint256 tokenId = _readyForPrincipalRedemption();
        pool.setPayoutDelta(tokenId, -10);

        bytes32 redeemedTopic = keccak256("PositionRedeemed(uint256,uint256,uint256,uint256)");

        vm.recordLogs();
        vault.pokeDecentral(0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawMismatch;
        bool sawRedeemed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == MISMATCH_TOPIC) sawMismatch = true;
            if (logs[i].topics[0] == redeemedTopic) sawRedeemed = true;
        }
        assertTrue(sawMismatch, "PrincipalMismatch fired");
        assertTrue(sawRedeemed, "PositionRedeemed still fires");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   FUZZ: arbitrary deltas always emit correctly
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_principalRedemption_arbitraryDelta(int128 delta) public {
        // Bound the delta to a sensible range so we don't underflow the principal
        delta = int128(bound(int256(delta), -1_000e18, 1_000e18));
        uint256 tokenId = _readyForPrincipalRedemption();
        pool.setPayoutDelta(tokenId, int256(delta));

        vm.recordLogs();
        vault.pokeDecentral(0);

        Mismatch[] memory ms = _collectMismatches();
        if (delta == 0) {
            assertEq(ms.length, 0, "no event when delta = 0");
        } else {
            assertEq(ms.length, 1, "exactly one event for non-zero delta");
            assertEq(ms[0].delta, int256(delta), "event delta matches injected delta");
            assertEq(ms[0].expected, TEN_THOUSAND_HOLLAR, "expected = principal");
            uint256 expectedReceived = delta >= 0
                ? TEN_THOUSAND_HOLLAR + uint256(int256(delta))
                : TEN_THOUSAND_HOLLAR - uint256(int256(-int256(delta)));
            assertEq(ms[0].received, expectedReceived, "received matches");
        }
    }
}
