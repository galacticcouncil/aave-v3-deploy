// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {MockHollar} from "../mocks/MockHollar.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";

import {UserHandler} from "./handlers/UserHandler.sol";
import {KeeperHandler} from "./handlers/KeeperHandler.sol";
import {AdminHandler} from "./handlers/AdminHandler.sol";
import {PositionReader} from "./helpers/PositionReader.sol";

/// @title HDCLVault Invariant Tests
/// @notice Verifies spec invariants (Section 6.3) hold under random call sequences.
contract InvariantVaultTest is Test {
    HDCLVault public vault;
    MockHollar public hollar;
    MockDecentralPool public pool;
    MockPoolToken public nft;

    UserHandler public userHandler;
    KeeperHandler public keeperHandler;
    AdminHandler public adminHandler;
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
        HDCLVault impl = new HDCLVault();
        bytes memory initData = abi.encodeCall(
            HDCLVault.initialize,
            (address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, FORTY_EIGHT_HOURS, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = HDCLVault(address(proxy));

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
        vault.deposit(10_000e18);

        // Deploy handlers and helpers
        userHandler = new UserHandler(vault, hollar, actors);
        keeperHandler = new KeeperHandler(vault, pool);
        adminHandler = new AdminHandler(vault, admin);
        posReader = new PositionReader(vault);

        // Tell Foundry which contracts to call
        targetContract(address(userHandler));
        targetContract(address(keeperHandler));
        targetContract(address(adminHandler));

        excludeContract(address(this));
        excludeContract(address(posReader));
    }

    // ── Helpers (use PositionReader to avoid struct destructuring issues) ──

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

    /// @notice totalQueuedHdcl <= vault's own HDCL balance (escrowed)
    function invariant_queueEscrowConsistent() public view {
        assertLe(
            vault.totalQueuedHdcl(),
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
    ///         Spec §4.3 notes "small corrections" from rounding but never below 1:1.
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

    /// @notice totalInvestedPrincipal == sum of principal for non-stale, non-redeemed positions.
    ///         NOTE: This invariant intermittently triggers a "replay failure" in Foundry's
    ///         sequence shrinking. The fuzzer detects a violation during random execution but
    ///         cannot minimize/reproduce it. This warrants manual investigation of the
    ///         mark/unmark stale accounting paths. All other 10 invariants pass consistently.
    function invariant_totalInvestedPrincipalAccurate() public view {
        uint256 count = vault.getPositionCount();
        uint256 sumPrincipal = 0;
        for (uint256 i = 0; i < count; i++) {
            (, uint256 principal, , , , uint8 state) = vault.getPosition(i);
            // Only count positions that are: not redeemed AND not stale
            if (state != 4 && !posReader.isStale(i)) {
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
    //           ACCOUNTING INVARIANT 8: totalStaleValue
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalStaleValue == sum of (stalePrincipal + staleYield) for non-redeemed stale positions.
    function invariant_totalStaleValueAccurate() public view {
        uint256 count = vault.getPositionCount();
        uint256 sumStale = 0;
        for (uint256 i = 0; i < count; i++) {
            (, , , , , uint8 state) = vault.getPosition(i);
            if (state != 4 && posReader.isStale(i)) {
                (uint256 sp, uint256 sy) = posReader.staleValues(i);
                sumStale += sp + sy;
            }
        }
        if (vault.totalStaleValue() != sumStale) {
            // Dump all positions for diagnosis
            for (uint256 i = 0; i < count; i++) {
                (, uint256 principal, , , , uint8 s) = vault.getPosition(i);
                bool stale = posReader.isStale(i);
                (uint256 sp2, uint256 sy2) = posReader.staleValues(i);
                console.log("--- pos", i, "---");
                console.log("  state:", s, "isStale:", stale ? 1 : 0);
                console.log("  principal:", principal);
                console.log("  stalePrincipal:", sp2, "staleYield:", sy2);
            }
            console.log("Contract totalStaleValue:", vault.totalStaleValue());
            console.log("Computed sum:", sumStale);
        }
        assertEq(vault.totalStaleValue(), sumStale, "INV-8: totalStaleValue mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          ACCOUNTING INVARIANT 9: positionHead Validity
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice All positions before positionHead must be Redeemed
    function invariant_positionHeadValid() public view {
        uint256 head = vault.getPositionHead();
        for (uint256 i = 0; i < head; i++) {
            (, , , , , uint8 state) = vault.getPosition(i);
            assertEq(state, 4, "INV-9: non-redeemed position before head");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //         ACCOUNTING INVARIANT 10: totalAssets Solvency
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice totalAssets >= idleHollar + totalInvestedPrincipal + totalStaleValue
    function invariant_totalAssetsSolvency() public view {
        uint256 floor = vault.totalInvestedPrincipal() + vault.idleHollar() + vault.totalStaleValue();
        assertGe(
            vault.totalAssets(),
            floor,
            "INV-10: totalAssets below component floor"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    CALL SUMMARY (for debugging)
    // ═══════════════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        console.log("--- Call Summary ---");
        console.log("Deposits:         ", userHandler.ghost_depositCount());
        console.log("Redeem requests:  ", userHandler.ghost_redeemRequestCount());
        console.log("  w/ floor accepted: ", userHandler.ghost_redeemFloorAccepted());
        console.log("  cap-rejected:    ", userHandler.ghost_redeemCapRejected());
        console.log("pokeDecentral:    ", keeperHandler.ghost_pokeDecentralCalls());
        console.log("pokeQueue:        ", keeperHandler.ghost_pokeQueueCalls());
        console.log("Shortfalls set:   ", keeperHandler.ghost_shortfallsConfigured());
        console.log("Time warps:       ", keeperHandler.ghost_timeWarps());
        console.log("Mark stale:       ", adminHandler.ghost_markStaleCalls());
        console.log("Unmark stale:     ", adminHandler.ghost_unmarkStaleCalls());
        console.log("Positions:        ", vault.getPositionCount());
        console.log("Exchange rate:    ", vault.exchangeRate());
        console.log("Total assets:     ", vault.totalAssets());
        console.log("Idle HOLLAR:      ", vault.idleHollar());
        console.log("Queued HDCL:      ", vault.totalQueuedHdcl());
    }
}
