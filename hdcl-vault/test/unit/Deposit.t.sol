// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";

contract DepositTest is BaseTest {
    /// @dev Matches the vault's Deposited event (4 params).
    ///      NOTE: Events.sol has a stale 5-param version — do not use it.
    event Deposited(
        address indexed user,
        uint256 hollarAmount,
        uint256 hdclMinted,
        uint256 tokenId
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                           REVERTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 1: Require !depositsPaused
    function test_deposit_reverts_whenDepositsPaused() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.expectRevert(HDCLVault.DepositsArePaused.selector);
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    /// @notice Spec §4.2 signature: whenNotPaused modifier (global pause)
    function test_deposit_reverts_whenGloballyPaused() public {
        vm.prank(admin);
        vault.pause();

        vm.expectRevert("Pausable: paused");
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    /// @notice Spec §4.2 step 2: Require hollarAmount > 0
    function test_deposit_reverts_whenZeroAmount() public {
        vm.expectRevert(HDCLVault.ZeroAmount.selector);
        _deposit(alice, 0);
    }

    /// @notice Spec §4.2 step 3: TVL cap check
    function test_deposit_reverts_whenTvlCapExceeded() public {
        vm.prank(admin);
        vault.setTvlCap(HUNDRED_HOLLAR);

        vm.expectRevert(HDCLVault.ExceedsTvlCap.selector);
        _deposit(alice, HUNDRED_HOLLAR + ONE_HOLLAR);
    }

    /// @notice Spec §4.2 step 3: deposit exactly at cap succeeds
    function test_deposit_succeedsAtExactTvlCap() public {
        vm.prank(admin);
        vault.setTvlCap(TEN_THOUSAND_HOLLAR);

        // Exact cap — should succeed
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertGt(hdcl, 0);
    }

    /// @notice Spec §4.2 step 3: one wei past cap reverts
    function test_deposit_reverts_onOneWeiPastTvlCap() public {
        vm.prank(admin);
        vault.setTvlCap(TEN_THOUSAND_HOLLAR);

        vm.expectRevert(HDCLVault.ExceedsTvlCap.selector);
        _deposit(alice, TEN_THOUSAND_HOLLAR + 1);
    }

    /// @notice Spec §4.2 step 4: Require wdclMinted > 0 (dust deposit)
    function test_deposit_reverts_whenMintedAmountIsZero() public {
        // Lower pool minimum so small deposits reach the vault's own check
        pool.setMinimumInvestmentAmount(1);

        // First deposit to establish supply
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Warp ~6 years so rate ≈ 2.08 (18% simple interest * 6)
        _warpDays(365 * 6);

        // Depositing 1 wei → 1 * supply / totalAssets rounds to 0
        vm.expectRevert("Deposit too small");
        _deposit(bob, 1);
    }

    /// @notice Spec §4.2 step 4: first deposit ≤ DEAD_SHARES reverts
    function test_deposit_reverts_whenFirstDepositTooSmall() public {
        pool.setMinimumInvestmentAmount(1);

        vm.expectRevert("Deposit too small");
        _deposit(alice, 1000); // exactly DEAD_SHARES
    }

    /// @notice Spec §4.2 edge case: Decentral pool revert → entire tx reverts
    function test_deposit_reverts_whenDecentralPoolReverts() public {
        pool.setPaused(true);

        vm.expectRevert("Pool paused");
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        FIRST DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 4 (totalSupply==0): wdclMinted = hollarAmount - DEAD_SHARES
    function test_firstDeposit_mintsAtOneToOneMinusDeadShares() public {
        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(hdcl, TEN_THOUSAND_HOLLAR - 1000);
        assertEq(vault.balanceOf(alice), TEN_THOUSAND_HOLLAR - 1000);
    }

    /// @notice Spec §4.2 step 4: 1000 dead shares sent to 0xdead
    function test_firstDeposit_mintsDeadSharesToDeadAddress() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(vault.balanceOf(address(0xdead)), 1000);
    }

    /// @notice Verify totalSupply = depositor shares + dead shares
    function test_firstDeposit_totalSupplyCorrect() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // totalSupply = user shares + dead shares = (amount - 1000) + 1000 = amount
        assertEq(vault.totalSupply(), TEN_THOUSAND_HOLLAR);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      SUBSEQUENT DEPOSITS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 4 (totalSupply>0): wdclMinted = hollarAmount * totalSupply / totalAssets
    function test_deposit_mintsCorrectHdclAtCurrentRate() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();

        uint256 bobHdcl = _deposit(bob, TEN_THOUSAND_HOLLAR);

        uint256 expected = (TEN_THOUSAND_HOLLAR * supplyBefore) / assetsBefore;
        assertEq(bobHdcl, expected, "HDCL minted should match rate formula");
    }

    /// @notice Spec: exchange rate appreciates → later depositors get fewer HDCL per HOLLAR
    function test_deposit_laterDepositorGetsFewer_whenRateAppreciated() public {
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);

        _warpDays(30);
        assertGt(vault.exchangeRate(), 1e18, "Rate should be > 1 after yield accrual");

        uint256 bobHdcl = _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertLt(bobHdcl, aliceHdcl, "Bob gets fewer HDCL at higher rate");
        assertLt(bobHdcl, TEN_THOUSAND_HOLLAR, "HDCL minted < HOLLAR deposited at rate > 1");
    }

    /// @notice Deposit must not change the exchange rate (no dilution / inflation)
    function test_deposit_preservesExchangeRate() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        uint256 rateBefore = vault.exchangeRate();

        _deposit(bob, TEN_THOUSAND_HOLLAR);

        uint256 rateAfter = vault.exchangeRate();
        // Within 0.01% for integer rounding
        assertApproxEqRel(rateBefore, rateAfter, 0.0001e18, "Exchange rate preserved");
    }

    /// @notice Multiple deposits create separate positions and track cumulative principal
    function test_deposit_multipleDeposits_cumulativeCorrectness() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionCount(), 2, "Two positions created");
        assertEq(
            vault.totalInvestedPrincipal(),
            2 * TEN_THOUSAND_HOLLAR,
            "Cumulative principal"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       TOKEN TRANSFERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 5: HOLLAR transferred from user
    function test_deposit_transfersHollarFromUser() public {
        uint256 balBefore = hollar.balanceOf(alice);

        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 balAfter = hollar.balanceOf(alice);
        assertEq(balBefore - balAfter, TEN_THOUSAND_HOLLAR, "User HOLLAR decreased by deposit amount");
    }

    /// @notice Spec §4.2 step 6: HDCL minted to depositor (not to vault or other address)
    function test_deposit_mintsHdclToDepositor() public {
        assertEq(vault.balanceOf(alice), 0, "Alice starts with 0 HDCL");

        uint256 hdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(vault.balanceOf(alice), hdcl, "HDCL minted directly to depositor");
        assertGt(hdcl, 0);
    }

    /// @notice Spec §4.2 step 7: entire hollarAmount deposited into Decentral.
    ///         Vault should not retain any HOLLAR — it all flows through to the pool.
    function test_deposit_hollarFlowsThroughToDecentral() public {
        uint256 vaultBalBefore = hollar.balanceOf(address(vault));
        uint256 poolBalBefore = hollar.balanceOf(address(pool));

        _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(
            hollar.balanceOf(address(vault)),
            vaultBalBefore,
            "Vault HOLLAR balance unchanged - HOLLAR flows through"
        );
        assertEq(
            hollar.balanceOf(address(pool)) - poolBalBefore,
            TEN_THOUSAND_HOLLAR,
            "Pool received full deposit amount"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    DECENTRAL INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 8: NFT position recorded with correct fields
    function test_deposit_recordsNFTPosition() public {
        uint256 tsBefore = block.timestamp;
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getPositionCount(), 1, "One position created");

        (
            uint256 tokenId,
            uint256 principal,
            uint256 apyWad,
            uint256 depositTime,
            uint256 maturityTime,
            uint8 state
        ) = vault.getPosition(0);

        assertGt(tokenId, 0, "Token ID > 0");
        assertEq(principal, TEN_THOUSAND_HOLLAR, "Principal matches deposit amount");
        assertEq(apyWad, APY_18_PERCENT, "APY matches decentralPool.fixedAPYWad()");
        assertEq(depositTime, tsBefore, "Deposit time is block.timestamp");
        assertEq(maturityTime, tsBefore + SIXTY_DAYS, "Maturity = depositTime + 60 days");
        assertEq(state, 0, "State is Active (0)");
    }

    /// @notice Spec §4.2: vault receives NFT via onERC721Received (implicit — deposit succeeds)
    function test_deposit_vaultOwnsNFT() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        (uint256 tokenId,,,,, ) = vault.getPosition(0);
        assertEq(nft.ownerOf(tokenId), address(vault), "Vault owns the Decentral NFT");
    }

    /// @notice onERC721Received only accepts callbacks from the configured
    ///         poolToken. Any other caller (e.g., arbitrary ERC721 contract
    ///         trying to spam the vault) is rejected. No fund-impact path
    ///         today, but prevents storage/event spam.
    function test_onERC721Received_rejectsForeignCaller() public {
        vm.prank(alice);
        vm.expectRevert("Only pool NFTs");
        vault.onERC721Received(alice, alice, 0, "");
    }

    /// @notice Positive case: when the configured poolToken makes the call,
    ///         the vault accepts and returns the standard selector. This is
    ///         the path triggered by `_safeMint` during deposit.
    function test_onERC721Received_acceptsFromPoolToken() public {
        vm.prank(address(nft));
        bytes4 selector = vault.onERC721Received(address(0), address(0), 0, "");
        assertEq(selector, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    APY BUCKET ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 8: bucket.totalPrincipal and bucket.weightedYieldStart updated
    function test_deposit_updatesBucketAccounting() public {
        uint256 ts = block.timestamp;

        _deposit(alice, TEN_THOUSAND_HOLLAR);

        (uint256 totalPrincipal, uint256 weightedYieldStart) = vault.apyBuckets(APY_18_PERCENT);
        assertEq(totalPrincipal, TEN_THOUSAND_HOLLAR, "Bucket totalPrincipal");
        assertEq(
            weightedYieldStart,
            TEN_THOUSAND_HOLLAR * ts,
            "Bucket weightedYieldStart = principal * timestamp"
        );
    }

    /// @notice Spec §4.2 step 8: totalInvestedPrincipal += hollarAmount
    function test_deposit_updatesTotalInvestedPrincipal() public {
        assertEq(vault.totalInvestedPrincipal(), 0, "Starts at 0");

        _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertEq(vault.totalInvestedPrincipal(), TEN_THOUSAND_HOLLAR, "After first deposit");

        _deposit(bob, HUNDRED_HOLLAR);
        assertEq(
            vault.totalInvestedPrincipal(),
            TEN_THOUSAND_HOLLAR + HUNDRED_HOLLAR,
            "After second deposit"
        );
    }

    /// @notice Deposits at different APY rates create separate buckets
    function test_deposit_createsNewBucket_whenApyChanges() public {
        // First deposit at 18%
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getActiveAPYCount(), 1);
        assertEq(vault.getActiveAPY(0), APY_18_PERCENT);

        // Change pool APY to 20%
        pool.setAPY(APY_20_PERCENT);

        // Second deposit at 20%
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.getActiveAPYCount(), 2, "Two distinct APY buckets");
        assertEq(vault.getActiveAPY(1), APY_20_PERCENT, "New bucket at 20%");

        (uint256 principal18,) = vault.apyBuckets(APY_18_PERCENT);
        (uint256 principal20,) = vault.apyBuckets(APY_20_PERCENT);
        assertEq(principal18, TEN_THOUSAND_HOLLAR, "18% bucket principal");
        assertEq(principal20, TEN_THOUSAND_HOLLAR, "20% bucket principal");
    }

    /// @notice Deposits go directly to Decentral — idleHollar stays 0
    function test_deposit_idleHollarRemainsZero() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertEq(vault.idleHollar(), 0, "Idle HOLLAR is 0 after first deposit");

        _deposit(bob, TEN_THOUSAND_HOLLAR);
        assertEq(vault.idleHollar(), 0, "Idle HOLLAR still 0 after second deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    QUEUE NON-INTERACTION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 edge case: redemption queue is NOT processed during deposits
    function test_deposit_doesNotProcessQueue() public {
        // Setup: Alice deposits, matures, processes, then queues redemption
        uint256 aliceHdcl = _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        uint256 redeemAmount = aliceHdcl / 2;
        _requestRedeem(alice, redeemAmount);

        uint256 queuedBefore = vault.totalQueuedHdcl();
        assertEq(queuedBefore, redeemAmount, "Queue has Alice's request");

        uint256 idleBefore = vault.idleHollar();

        // Bob deposits — queue must remain untouched
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(vault.totalQueuedHdcl(), queuedBefore, "Queue unchanged after deposit");
        // idleHollar should also remain the same (deposit doesn't add to idle)
        assertEq(vault.idleHollar(), idleBefore, "Idle HOLLAR unchanged by deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §4.2 step 9: Deposited(msg.sender, hollarAmount, wdclMinted, tokenId)
    function test_deposit_emitsDepositedEvent() public {
        vm.expectEmit(true, false, false, true);
        // We don't know exact hdclMinted and tokenId ahead of time, so check topic1 (user)
        // and verify data fields match after the call.
        emit Deposited(alice, TEN_THOUSAND_HOLLAR, TEN_THOUSAND_HOLLAR - 1000, 1);

        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        previewDeposit
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice previewDeposit when supply == 0: returns hollarAmount - DEAD_SHARES
    function test_previewDeposit_zeroSupply() public view {
        uint256 preview = vault.previewDeposit(TEN_THOUSAND_HOLLAR);
        assertEq(preview, TEN_THOUSAND_HOLLAR - 1000, "Preview at zero supply = amount - dead shares");
    }

    /// @notice previewDeposit when supply > 0: matches actual deposit
    function test_previewDeposit_withExistingSupply() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(30);

        uint256 preview = vault.previewDeposit(TEN_THOUSAND_HOLLAR);
        uint256 actual = _deposit(bob, TEN_THOUSAND_HOLLAR);

        assertEq(preview, actual, "Preview should match actual deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Calculate expected yield: principal * apyWad * seconds / (SECONDS_PER_YEAR * 1e18)
    function _expectedYield(
        uint256 principal,
        uint256 apyWad,
        uint256 days_
    ) internal pure returns (uint256) {
        return (principal * apyWad * days_ * SECONDS_PER_DAY) / (365 days * 1e18);
    }
}
