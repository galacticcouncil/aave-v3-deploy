// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {MockHollar} from "../mocks/MockHollar.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

/// @title Multi-Pool Support
/// @notice Verifies the vault can rotate across Decentral pools without losing
///         continuity for already-open positions.
contract MultiPoolTest is BaseTest {
    MockDecentralPool internal pool2;
    MockPoolToken internal nft2;

    uint256 internal constant APY_20 = 0.20e18;
    uint256 internal constant APY_25 = 0.25e18;

    function setUp() public override {
        super.setUp();

        // Stand up a second Decentral pool at a different APY, sharing the
        // same HOLLAR token but with its own NFT contract.
        nft2 = new MockPoolToken();
        pool2 = new MockDecentralPool(address(hollar), address(nft2), APY_20);
        nft2.registerPool(address(pool2));
        hollar.mint(address(pool2), 10_000_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   REGISTER / SET ACTIVE / RETIRE — happy path + guards
    // ═══════════════════════════════════════════════════════════════════════

    function test_registerPool_succeeds() public {
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));

        assertTrue(vault.isPoolRegistered(IDecentralPool(address(pool2))));
        assertTrue(vault.isRegisteredPoolToken(address(nft2)));
        assertEq(vault.getPoolCount(), 2);
    }

    function test_registerPool_rejectsDuplicate() public {
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));

        vm.expectRevert(HDCLVault.PoolAlreadyRegistered.selector);
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));
    }

    function test_registerPool_rejectsWrongStablecoin() public {
        MockHollar otherHollar = new MockHollar();
        MockPoolToken nft3 = new MockPoolToken();
        MockDecentralPool pool3 = new MockDecentralPool(
            address(otherHollar),
            address(nft3),
            APY_25
        );

        vm.expectRevert(HDCLVault.PoolWrongStablecoin.selector);
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool3)));
    }

    function test_setActiveDepositPool_succeeds() public {
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));

        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool2)));

        assertEq(address(vault.activeDepositPool()), address(pool2));
    }

    function test_setActiveDepositPool_rejectsUnregistered() public {
        vm.expectRevert(HDCLVault.PoolNotRegistered.selector);
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool2)));
    }

    function test_retirePool_succeeds_whenNoPositions() public {
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));

        // pool2 is registered but never received a deposit
        vm.prank(admin);
        vault.retirePool(IDecentralPool(address(pool2)));

        assertFalse(vault.isPoolRegistered(IDecentralPool(address(pool2))));
        assertFalse(vault.isRegisteredPoolToken(address(nft2)));
        assertEq(vault.getPoolCount(), 1);
    }

    function test_retirePool_revertsOnActivePool() public {
        // The initial pool is the active one; can't retire it
        vm.expectRevert(HDCLVault.CannotRetireActivePool.selector);
        vm.prank(admin);
        vault.retirePool(IDecentralPool(address(pool)));
    }

    function test_retirePool_revertsWithOpenPositions() public {
        // Register pool2, switch to it, deposit, then try to retire the original.
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool2)));

        // Alice deposits into the active pool (pool2)
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Now try to retire pool2 — it's still active, blocked by that check
        vm.expectRevert(HDCLVault.CannotRetireActivePool.selector);
        vm.prank(admin);
        vault.retirePool(IDecentralPool(address(pool2)));

        // Switch back to pool 1 so pool2 is no longer active but still has a position
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool)));

        vm.expectRevert(HDCLVault.PoolHasOpenPositions.selector);
        vm.prank(admin);
        vault.retirePool(IDecentralPool(address(pool2)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   HETEROGENEOUS APYS — positions from different pools accrue correctly
    // ═══════════════════════════════════════════════════════════════════════

    function test_heterogeneousAPY_totalAssetsCorrect() public {
        // Alice deposits into pool 1 at 18%
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Register pool 2 (20%) and switch
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool2)));

        // Bob deposits into pool 2 at 20%
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // Sanity: each position has its own pool stored
        assertEq(address(vault.positionPool(0)), address(pool));
        assertEq(address(vault.positionPool(1)), address(pool2));

        // Warp 30 days; accruedYield must sum both rates
        _warpDays(30);

        uint256 yield1 = TEN_THOUSAND_HOLLAR * APY_18_PERCENT * 30 * SECONDS_PER_DAY / (365 days * 1e18);
        uint256 yield2 = TEN_THOUSAND_HOLLAR * APY_20 * 30 * SECONDS_PER_DAY / (365 days * 1e18);
        uint256 expected = 2 * TEN_THOUSAND_HOLLAR + yield1 + yield2;

        assertApproxEqRel(vault.totalAssets(), expected, 0.01e18, "totalAssets sums heterogeneous APYs");
    }

    function test_pokeDecentral_routesThroughPositionPool() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));
        vm.prank(admin);
        vault.setActiveDepositPool(IDecentralPool(address(pool2)));
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        _warpDays(61);

        // Process position 0 (pool 1) all the way to Redeemed
        _processPositionFull(0);
        (, , , , , uint8 state0) = vault.getPosition(0);
        assertEq(state0, 4, "position 0 redeemed");

        // Process position 1 (pool 2) — it should route through pool2, not the
        // original pool. If routing were stuck on pool 1, pool 1 wouldn't have
        // a yield request for token id 1.
        vault.pokeDecentral(1);
        (uint256 tokenId1, , , , , uint8 state1) = vault.getPosition(1);
        assertEq(state1, 1, "position 1 advanced to YWR via its own pool");

        pool2.approveYieldWithdrawal(tokenId1);
        vault.pokeDecentral(1);
        (, , , , , uint8 state1b) = vault.getPosition(1);
        assertEq(state1b, 3, "position 1 advanced to PWR via pool2");
    }

    function test_onERC721Received_acceptsFromAnyRegisteredPool() public {
        // pool 1's NFT contract is registered at init
        assertTrue(vault.isRegisteredPoolToken(address(nft)));

        // pool 2's NFT contract gets registered when admin registers pool 2
        vm.prank(admin);
        vault.registerPool(IDecentralPool(address(pool2)));
        assertTrue(vault.isRegisteredPoolToken(address(nft2)));

        // Direct receive from registered NFT contract works
        vm.prank(address(nft));
        bytes4 ret = vault.onERC721Received(address(0), address(0), 0, "");
        assertEq(ret, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));

        vm.prank(address(nft2));
        ret = vault.onERC721Received(address(0), address(0), 0, "");
        assertEq(ret, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));

        // Random NFT contract rejected
        MockPoolToken stranger = new MockPoolToken();
        vm.expectRevert(HDCLVault.OnlyPoolNFTs.selector);
        vm.prank(address(stranger));
        vault.onERC721Received(address(0), address(0), 0, "");
    }
}
