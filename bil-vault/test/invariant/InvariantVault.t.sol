// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BILVault} from "../../src/BILVault.sol";
import {MockHollar} from "../mocks/MockHollar.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

import {UserHandler} from "./handlers/UserHandler.sol";
import {KeeperHandler} from "./handlers/KeeperHandler.sol";
import {PositionReader} from "./helpers/PositionReader.sol";

/// @title BILVault Invariant Tests
/// @notice Verifies spec invariants (Section 6.3) hold under random call sequences.
contract InvariantVaultTest is Test {
    BILVault public vault;
    MockHollar public hollar;
    MockDecentralPool public pool;
    MockPoolToken public nft;

    UserHandler public userHandler;
    KeeperHandler public keeperHandler;
    PositionReader public posReader;

    address public admin = makeAddr("admin");
    address[] public actors;

    uint256 constant APY_18_PERCENT = 0.18e18;
    uint256 constant INITIAL_TVL_CAP = 2_000_000e18;
    uint256 constant FORTY_EIGHT_HOURS = 48 hours;

    function setUp() public {
        // Deploy mocks
        hollar = new MockHollar();
        nft = new MockPoolToken();
        pool = new MockDecentralPool(address(hollar), address(nft), APY_18_PERCENT);
        nft.registerPool(address(pool));

        // Fund pool for yield payouts
        hollar.mint(address(pool), 10_000_000e18);

        // Deploy vault via proxy
        BILVault impl = new BILVault();
        bytes memory initData = abi.encodeCall(
            BILVault.initialize,
            (address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BILVault(address(proxy));

        // Create actors with HOLLAR balances and approvals
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(actor);
            hollar.mint(actor, 100_000e18);
            vm.prank(actor);
            hollar.approve(address(vault), type(uint256).max);
        }

        // Seed vault with an initial deposit so we're past the dead-shares edge case
        vm.prank(actors[0]);
        vault.deposit(10_000e18, actors[0]);

        // Deploy handlers and helpers
        userHandler = new UserHandler(vault, hollar, actors);
        keeperHandler = new KeeperHandler(vault, pool);
        posReader = new PositionReader(vault);

        // Tell Foundry which contracts to call
        targetContract(address(userHandler));
        targetContract(address(keeperHandler));

        excludeContract(address(this));
        excludeContract(address(posReader));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //               SPEC INVARIANT 1: Shares Have Backing
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalSupply() > 0 implies totalAssets() > 0
    function invariant_sharesHaveBacking() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.totalAssets(), 0, "INV-1: shares without backing");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //             SPEC INVARIANT 2: Idle Not Over-Counted
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice idleHollar <= hollar.balanceOf(vault)
    function invariant_idleNotOverCounted() public view {
        assertLe(
            vault.idleHollar(),
            hollar.balanceOf(address(vault)),
            "INV-2: idle over-counted"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //            SPEC INVARIANT 3: Queue Escrow Consistent
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalQueuedBil <= vault's own BIL balance (escrowed)
    function invariant_queueEscrowConsistent() public view {
        assertLe(
            vault.totalQueuedBil(),
            vault.balanceOf(address(vault)),
            "INV-3: queue escrow inconsistent"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         SPEC INVARIANT 4: NFT Ownership
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Non-redeemed positions must have their NFTs owned by the vault
    function invariant_nftOwnership() public view {
        uint256 count = vault.getPositionCount();
        for (uint256 i = 0; i < count; i++) {
            (uint256 tokenId, , , , , uint8 state) = vault.getPosition(i);
            if (state != 4) {
                assertEq(
                    nft.ownerOf(tokenId),
                    address(vault),
                    "INV-4: vault doesn't own non-redeemed NFT"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //       SPEC INVARIANT 5: Exchange Rate Always >= 1e18
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Exchange rate should always be >= 1e18 (initial rate).
    ///         The rate starts at 1e18 and should only go up as yield accrues.
    function invariant_exchangeRateAboveInitial() public view {
        if (vault.totalSupply() > 0) {
            assertGe(
                vault.exchangeRate(),
                1e18,
                "INV-5: exchange rate below 1:1"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //       SPEC INVARIANT 6: Valid Position States
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Position states are always in [0, 4]
    function invariant_validPositionStates() public view {
        uint256 count = vault.getPositionCount();
        for (uint256 i = 0; i < count; i++) {
            (, , , , , uint8 state) = vault.getPosition(i);
            assertLe(state, 4, "INV-6: invalid position state");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //           ACCOUNTING INVARIANT 7: totalInvestedPrincipal
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalInvestedPrincipal == sum of principal for non-redeemed positions.
    function invariant_totalInvestedPrincipalAccurate() public view {
        uint256 count = vault.getPositionCount();
        uint256 sumPrincipal = 0;
        for (uint256 i = 0; i < count; i++) {
            (, uint256 principal, , , , uint8 state) = vault.getPosition(i);
            if (state != 4) {
                sumPrincipal += principal;
            }
        }
        assertEq(
            vault.totalInvestedPrincipal(),
            sumPrincipal,
            "INV-7: totalInvestedPrincipal mismatch"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          ACCOUNTING INVARIANT 8: positionHead Validity
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice All positions before positionHead must be Redeemed
    function invariant_positionHeadValid() public view {
        uint256 head = vault.getPositionHead();
        for (uint256 i = 0; i < head; i++) {
            (, , , , , uint8 state) = vault.getPosition(i);
            assertEq(state, 4, "INV-8: non-redeemed position before head");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         ACCOUNTING INVARIANT 9: totalAssets Solvency
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalAssets >= idleHollar + totalInvestedPrincipal + totalReservedHollar
    function invariant_totalAssetsSolvency() public view {
        uint256 floor = vault.totalInvestedPrincipal()
            + vault.idleHollar()
            + vault.totalReservedHollar();
        assertGe(
            vault.totalAssets(),
            floor,
            "INV-9: totalAssets below component floor"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //      ACCOUNTING INVARIANT 10: totalReservedHollar accuracy
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalReservedHollar == sum of hollarOwed across all non-deleted requests.
    function invariant_totalReservedHollarAccurate() public view {
        uint256 tail = vault.getRedemptionQueueLength();
        uint256 sum = 0;
        for (uint256 i = 0; i < tail; i++) {
            (address u, , , uint256 owed, ) = vault.getRedemptionRequest(i);
            if (u != address(0)) sum += owed;
        }
        assertEq(
            vault.totalReservedHollar(),
            sum,
            "INV-10: totalReservedHollar mismatch"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //       ACCOUNTING INVARIANT 11: totalQueuedBil accuracy
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalQueuedBil == sum of bilAmount across all non-deleted requests.
    function invariant_totalQueuedBilAccurate() public view {
        uint256 tail = vault.getRedemptionQueueLength();
        uint256 sum = 0;
        for (uint256 i = 0; i < tail; i++) {
            (address u, uint256 amt, , , ) = vault.getRedemptionRequest(i);
            if (u != address(0)) sum += amt;
        }
        assertEq(
            vault.totalQueuedBil(),
            sum,
            "INV-11: totalQueuedBil mismatch"
        );
    }

    /// @notice totalSettledBil == sum of bilSettled across all requests, and
    ///         never exceeds totalSupply (settled shares are a subset of
    ///         escrowed shares). Underpins the active-share exchange rate.
    function invariant_totalSettledBilAccurate() public view {
        uint256 tail = vault.getRedemptionQueueLength();
        uint256 sum = 0;
        for (uint256 i = 0; i < tail; i++) {
            (address u, , uint256 settled, , ) = vault.getRedemptionRequest(i);
            if (u != address(0)) sum += settled;
        }
        assertEq(vault.totalSettledBil(), sum, "INV-13: totalSettledBil mismatch");
        assertLe(vault.totalSettledBil(), vault.totalSupply(), "settled exceeds supply");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          ACCOUNTING INVARIANT 12: HOLLAR backing
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The vault's HOLLAR balance must cover both idle and reserved
    ///         claims. A break here means we've spent HOLLAR that was supposed
    ///         to back unclaimed redemptions, or the accounting drifted away
    ///         from the real token balance.
    function invariant_hollarBacking() public view {
        assertGe(
            hollar.balanceOf(address(vault)),
            vault.idleHollar() + vault.totalReservedHollar(),
            "INV-12: vault HOLLAR balance < idle + reserved"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         ACCOUNTING INVARIANT 13: Per-request consistency
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice For every live request: bilSettled <= bilAmount, and
    ///         hollarOwed > 0 only if bilSettled > 0 (no HOLLAR locked for
    ///         zero shares).
    function invariant_perRequestConsistency() public view {
        uint256 tail = vault.getRedemptionQueueLength();
        for (uint256 i = 0; i < tail; i++) {
            (address u, uint256 amt, uint256 settled, uint256 owed, ) =
                vault.getRedemptionRequest(i);
            if (u == address(0)) continue;
            assertLe(settled, amt, "INV-13a: bilSettled > bilAmount");
            if (settled == 0) {
                assertEq(owed, 0, "INV-13b: HOLLAR locked for zero shares");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ACCOUNTING INVARIANT 14: positionPool integrity
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Every non-Redeemed position is anchored to a still-registered
    ///         pool. retirePool enforces this in the forward direction; this
    ///         invariant catches any path that could violate it backwards.
    function invariant_positionPoolIntegrity() public view {
        uint256 count = vault.getPositionCount();
        for (uint256 i = 0; i < count; i++) {
            (, , , , , uint8 state) = vault.getPosition(i);
            if (state == 4) continue;
            assertTrue(
                vault.isPoolRegistered(vault.positionPool(i)),
                "INV-14: live position references unregistered pool"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    CALL SUMMARY (for debugging)
    // ═══════════════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        console.log("--- Call Summary ---");
        console.log("Deposits:         ", userHandler.ghost_depositCount());
        console.log("Redeem requests:  ", userHandler.ghost_redeemRequestCount());
        console.log("Claims:           ", userHandler.ghost_claimCount());
        console.log("Auto-claim toggles:", userHandler.ghost_autoClaimToggles());
        console.log("Operator sets:    ", userHandler.ghost_operatorSets());
        console.log("pokeDecentral:    ", keeperHandler.ghost_pokeDecentralCalls());
        console.log("pokeQueue:        ", keeperHandler.ghost_pokeQueueCalls());
        console.log("Shortfalls set:   ", keeperHandler.ghost_shortfallsConfigured());
        console.log("Time warps:       ", keeperHandler.ghost_timeWarps());
        console.log("Positions:        ", vault.getPositionCount());
        console.log("Exchange rate:    ", vault.exchangeRate());
        console.log("Total assets:     ", vault.totalAssets());
        console.log("Idle HOLLAR:      ", vault.idleHollar());
        console.log("Reserved HOLLAR:  ", vault.totalReservedHollar());
        console.log("Queued BIL:      ", vault.totalQueuedBil());
    }
}
