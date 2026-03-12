// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";

contract ExchangeRateTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════
    //                      INITIAL STATE
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_initiallyOne() public view {
        // With zero supply, exchange rate should be 1e18 (1:1)
        assertEq(vault.exchangeRate(), 1e18, "Initial exchange rate should be 1e18");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      RATE APPRECIATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_increasesOverTime() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 rateAtDeposit = vault.exchangeRate();

        // Warp 30 days -- yield accrues
        _warpDays(30);

        uint256 rateAfter30Days = vault.exchangeRate();
        assertGt(rateAfter30Days, rateAtDeposit, "Rate should increase after 30 days");
    }

    function test_exchangeRate_correctAfter30Days() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);
        uint256 totalSupply = vault.totalSupply();

        _warpDays(30);

        // Manual calculation:
        // yield = principal * 0.18 * 30 * 86400 / (365 * 86400) / 1e18
        //       = principal * 0.18 * 30 / 365
        uint256 expectedYield = depositAmount * APY_18_PERCENT * 30 * SECONDS_PER_DAY
            / (365 days * 1e18);
        uint256 expectedTotalAssets = depositAmount + expectedYield;
        uint256 expectedRate = expectedTotalAssets * 1e18 / totalSupply;

        uint256 actualRate = vault.exchangeRate();
        assertApproxEqRel(actualRate, expectedRate, 0.01e18, "Rate after 30 days should match manual calc");
    }

    function test_exchangeRate_correctAfter60Days() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);
        uint256 totalSupply = vault.totalSupply();

        _warpDays(60);

        // Full 60-day yield
        uint256 expectedYield = depositAmount * APY_18_PERCENT * 60 * SECONDS_PER_DAY
            / (365 days * 1e18);
        uint256 expectedTotalAssets = depositAmount + expectedYield;
        uint256 expectedRate = expectedTotalAssets * 1e18 / totalSupply;

        uint256 actualRate = vault.exchangeRate();
        assertApproxEqRel(actualRate, expectedRate, 0.01e18, "Rate after 60 days should match manual calc");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    MULTIPLE APY BUCKETS
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_multipleAPYBuckets() public {
        // Deposit at 18% APY
        uint256 deposit1 = TEN_THOUSAND_HOLLAR;
        _deposit(alice, deposit1);

        // Change pool APY to 20%
        pool.setAPY(APY_20_PERCENT);

        // Deposit at 20% APY
        uint256 deposit2 = TEN_THOUSAND_HOLLAR;
        _deposit(bob, deposit2);

        uint256 totalSupply = vault.totalSupply();

        // Verify two APY buckets exist
        assertEq(vault.getActiveAPYCount(), 2, "Should have 2 active APY buckets");

        // Warp 30 days
        _warpDays(30);

        // Manual calculation of totalAssets:
        // Yield from 18% bucket: deposit1 * 0.18 * 30/365
        // Yield from 20% bucket: deposit2 * 0.20 * 30/365
        uint256 yield18 = deposit1 * APY_18_PERCENT * 30 * SECONDS_PER_DAY / (365 days * 1e18);
        uint256 yield20 = deposit2 * APY_20_PERCENT * 30 * SECONDS_PER_DAY / (365 days * 1e18);
        uint256 expectedTotalAssets = deposit1 + deposit2 + yield18 + yield20;

        uint256 actualTotalAssets = vault.totalAssets();
        assertApproxEqRel(
            actualTotalAssets,
            expectedTotalAssets,
            0.01e18,
            "Total assets should include yield from both APY buckets"
        );

        // Exchange rate should reflect combined yield
        uint256 expectedRate = expectedTotalAssets * 1e18 / totalSupply;
        uint256 actualRate = vault.exchangeRate();
        assertApproxEqRel(actualRate, expectedRate, 0.01e18, "Rate should reflect multi-bucket yield");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    YIELD CLAIM PRESERVATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_afterYieldClaim() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);

        // Warp past maturity
        _warpDays(61);

        uint256 rateBefore = vault.exchangeRate();

        // Process position: request yield withdrawal
        vault.processPosition(0);

        // Approve and execute yield withdrawal
        (uint256 tokenId,,,,, ) = vault.getPosition(0);
        pool.approveYieldWithdrawal(tokenId);
        vault.processPosition(0);

        // After yield claim, the rate should be approximately preserved
        // because the yield moved from "accrued" to "idleHollar" and
        // the bucket's yieldStartTime was reset
        uint256 rateAfter = vault.exchangeRate();
        assertApproxEqRel(
            rateAfter,
            rateBefore,
            0.01e18,
            "Exchange rate should be approximately preserved after yield claim"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      IDLE HOLLAR INCLUSION
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_includesIdleHollar() public {
        // First deposit creates a position
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Set minReinvestAmount very high so deposit goes to idleHollar
        vm.prank(admin);
        vault.setMinReinvestAmount(100_000e18);

        // Second deposit goes entirely to idleHollar
        uint256 idleDeposit = HUNDRED_HOLLAR;
        _deposit(bob, idleDeposit);

        // Verify idleHollar is tracked
        assertEq(vault.idleHollar(), idleDeposit, "Idle HOLLAR should equal Bob's deposit");

        // totalAssets should include idle HOLLAR
        uint256 totalAssets = vault.totalAssets();
        assertGe(
            totalAssets,
            TEN_THOUSAND_HOLLAR + idleDeposit,
            "Total assets should include idle HOLLAR"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    DONATION ATTACK RESISTANCE
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_donationDoesNotAffect() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 rateBefore = vault.exchangeRate();

        // External HOLLAR transfer directly to vault (donation / inflation attack)
        hollar.mint(address(vault), TEN_THOUSAND_HOLLAR);

        uint256 rateAfter = vault.exchangeRate();

        // Rate should NOT change because the vault tracks assets via
        // totalInvestedPrincipal + accruedYield + idleHollar, not raw balanceOf
        assertEq(rateAfter, rateBefore, "Donation should not affect exchange rate");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      TOTAL ASSETS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_totalAssets_matchesExpectedYield() public {
        uint256 depositAmount = TEN_THOUSAND_HOLLAR;
        _deposit(alice, depositAmount);

        _warpDays(45);

        // Expected yield: principal * apyWad * elapsed / SECONDS_PER_YEAR / 1e18
        uint256 elapsed = 45 * SECONDS_PER_DAY;
        uint256 expectedYield = depositAmount * APY_18_PERCENT * elapsed / (365 days * 1e18);
        uint256 expectedTotalAssets = depositAmount + expectedYield;

        uint256 actualTotalAssets = vault.totalAssets();
        assertApproxEqRel(
            actualTotalAssets,
            expectedTotalAssets,
            0.01e18,
            "Total assets should match expected principal + yield"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    MONOTONIC INCREASE
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_monotonicallyIncreasing() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 previousRate = vault.exchangeRate();

        // Check rate at 10, 20, 30, 40, 50, 60 days
        for (uint256 d = 10; d <= 60; d += 10) {
            _warpDays(10); // warp 10 more days each iteration
            uint256 currentRate = vault.exchangeRate();
            assertGt(
                currentRate,
                previousRate,
                string.concat("Rate should increase at day ", vm.toString(d))
            );
            previousRate = currentRate;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    ADDITIONAL RATE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function test_exchangeRate_nearOneAfterFirstDeposit() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Immediately after first deposit, rate should be very close to 1e18
        // (only dead shares cause a tiny deviation)
        uint256 rate = vault.exchangeRate();
        assertApproxEqRel(rate, 1e18, 0.001e18, "Rate should be ~1e18 right after first deposit");
    }

    function test_totalAssets_zeroBeforeDeposits() public view {
        assertEq(vault.totalAssets(), 0, "Total assets should be 0 before any deposits");
    }
}
