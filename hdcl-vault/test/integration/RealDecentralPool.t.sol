// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Real Decentral protocol contracts (vendored via lib/decentral-contracts)
import {DecentralPool} from "decentral-contracts/DecentralPool.sol";
import {PoolToken} from "decentral-contracts/PoolToken.sol";
import {DecentralFactory} from "decentral-contracts/DecentralFactory.sol";

// Vault under test
import {HDCLVault} from "../../src/HDCLVault.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {IPoolToken} from "../../src/interfaces/IPoolToken.sol";
import {MockHollar} from "../mocks/MockHollar.sol";

/// @title End-to-end test against the *real* Decentral protocol source
/// @notice The unit-test suite runs against `MockDecentralPool`, a faithful
///         re-implementation. That catches our integration logic but can't
///         catch divergences between the mock and Decentral's actual
///         bytecode/math. This file vendors the canonical Decentral source
///         (`lib/decentral-contracts` submodule) and deploys it locally so
///         we exercise the full `deposit → mature → request → approve →
///         execute → queue settle → user claim` lifecycle against the real
///         contracts with `vm.warp` for time travel.
///
///         Scope: confidence test, not exhaustive — one happy-path flow
///         covering the things `vm.warp` makes accessible that lark-2 can't
///         (60-day investment period, 1h principal-withdrawal delay).
contract RealDecentralPoolTest is Test {
    // ─── Actors ────────────────────────────────────────────────────────────
    address constant ADMIN = address(0xA);
    address constant USER = address(0xB);
    address constant KEEPER = address(0xC);

    // ─── Contracts ─────────────────────────────────────────────────────────
    MockHollar hollar;
    PoolToken poolToken;
    DecentralFactory factory;
    DecentralPool pool; // proxy
    HDCLVault vault; // proxy

    // ─── Pool parameters ──────────────────────────────────────────────────
    uint256 constant DEPOSIT = 100e18;
    uint256 constant TVL_CAP = 1_000_000e18;
    uint256 constant POOL_LIQUIDITY_BUFFER = 1_000e18; // covers yield payouts
    uint256 constant FIXED_APY_BPS = 1800; // 18%
    uint256 constant PAYMENT_FREQUENCY_DAYS = 30;
    uint256 constant MIN_INVESTMENT_PERIOD_DAYS = 60;
    uint256 constant PRINCIPAL_DELAY_HOURS = 1;
    uint256 constant MIN_INVESTMENT = 1e18;
    uint256 constant MAX_INVESTMENT = 1_000_000e18;

    function setUp() public {
        vm.startPrank(ADMIN);

        // ─── 1. HOLLAR stablecoin ─────────────────────────────────────────
        hollar = new MockHollar();

        // ─── 2. PoolToken behind an ERC1967 proxy (Decentral uses UUPS) ──
        PoolToken poolTokenImpl = new PoolToken();
        bytes memory ptInit = abi.encodeWithSelector(
            PoolToken.initialize.selector,
            "DecentralPool Token",
            "DPT",
            "", // baseURI
            ADMIN
        );
        ERC1967Proxy ptProxy = new ERC1967Proxy(address(poolTokenImpl), ptInit);
        poolToken = PoolToken(address(ptProxy));

        // ─── 3. DecentralFactory behind a proxy ─────────────────────────
        DecentralPool poolImpl = new DecentralPool();
        DecentralFactory factoryImpl = new DecentralFactory();
        bytes memory fInit = abi.encodeWithSelector(
            DecentralFactory.initialize.selector,
            address(poolToken),
            address(poolImpl),
            ADMIN
        );
        ERC1967Proxy fProxy = new ERC1967Proxy(address(factoryImpl), fInit);
        factory = DecentralFactory(address(fProxy));

        // ─── 4. Factory needs ADMIN_ROLE on PoolToken to call registerPool
        //       (PoolToken.registerPool grants the new pool POOL_ROLE +
        //       BURNER_ROLE so it can mint/burn its own NFTs).
        poolToken.grantRole(poolToken.ADMIN_ROLE(), address(factory));

        // ─── 5. Create the pool ───────────────────────────────────────────
        address poolAddr = factory.createPool(
            address(hollar),
            FIXED_APY_BPS,
            PAYMENT_FREQUENCY_DAYS,
            MIN_INVESTMENT_PERIOD_DAYS,
            PRINCIPAL_DELAY_HOURS,
            MIN_INVESTMENT,
            MAX_INVESTMENT
        );
        pool = DecentralPool(poolAddr);

        // ─── 6. HDCLVault behind a proxy ─────────────────────────────────
        HDCLVault vaultImpl = new HDCLVault();
        bytes memory vInit = abi.encodeWithSelector(
            HDCLVault.initialize.selector,
            poolAddr,
            address(poolToken),
            address(hollar),
            TVL_CAP,
            ADMIN
        );
        ERC1967Proxy vProxy = new ERC1967Proxy(address(vaultImpl), vInit);
        vault = HDCLVault(address(vProxy));

        // ─── 7. Pre-fund pool with HOLLAR to cover yield payouts on execute
        //       (the pool model assumes the borrower repays before yield is
        //       withdrawn; here we shortcut by injecting liquidity directly).
        hollar.mint(address(pool), POOL_LIQUIDITY_BUFFER);

        vm.stopPrank();

        // ─── 8. User starting balance ────────────────────────────────────
        hollar.mint(USER, DEPOSIT);
    }

    // ════════════════════════════════════════════════════════════════════
    //                                TESTS
    // ════════════════════════════════════════════════════════════════════

    /// Full happy-path: deposit → mature → poke through state machine →
    /// queue settles → user redeems HOLLAR. Validates that the real Decentral
    /// pool's deposit/yield/principal lifecycle plays nicely with the
    /// vault's `pokeDecentral` state machine.
    function test_FullDepositMatureRedeemCycle() public {
        // ─── User deposits HOLLAR into the vault ─────────────────────────
        vm.startPrank(USER);
        hollar.approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, USER);
        vm.stopPrank();

        assertGt(shares, 0, "user receives hDCL shares");
        assertEq(
            vault.totalAssets(),
            DEPOSIT,
            "vault totalAssets == deposit (no time elapsed)"
        );
        assertEq(vault.getPositionCount(), 1, "one Decentral position opened");

        // The vault holds the NFT minted by the pool.
        uint256 nftCount = poolToken.balanceOf(address(vault));
        assertEq(nftCount, 1, "vault holds 1 Decentral NFT");

        // ─── Queue a redemption now; nothing settles yet (no liquidity) ──
        vm.prank(USER);
        uint256 reqId = vault.requestRedeem(shares, USER, USER);

        (
            ,
            ,
            uint256 settledBefore,
            ,
            bool activeBefore
        ) = vault.getRedemptionRequest(reqId);
        assertEq(settledBefore, 0, "nothing settled yet");
        assertTrue(activeBefore, "request active");

        // pokeQueue with no idle HOLLAR is a no-op — confirm settled stays 0.
        vault.pokeQueue();
        (, , uint256 settledAfterPoke, , ) = vault.getRedemptionRequest(reqId);
        assertEq(settledAfterPoke, 0, "still nothing settled");

        // ─── Warp past the 60-day minimum investment period ──────────────
        vm.warp(block.timestamp + 60 days + 1);

        // Get the NFT's tokenId. The vault opened the position at index 0.
        (uint256 tokenId, , , , , uint8 stateBefore) = vault.getPosition(0);
        assertEq(stateBefore, 0, "position is Active before maturity poke");

        // ─── First poke: Active → YieldWithdrawalRequested ───────────────
        vm.prank(KEEPER);
        vault.pokeDecentral(0);

        (, , , , , uint8 stateAfterFirstPoke) = vault.getPosition(0);
        assertEq(
            stateAfterFirstPoke,
            1,
            "position is YieldWithdrawalRequested after first poke"
        );

        // Confirm Decentral sees the yield request.
        (, , bool yieldReqExists, bool yieldReqApproved) = pool
            .getYieldWithdrawalRequest(tokenId);
        assertTrue(yieldReqExists, "Decentral has a yield withdrawal request");
        assertFalse(yieldReqApproved, "yield request not yet approved");

        // ─── Decentral admin approves the yield ──────────────────────────
        vm.prank(ADMIN);
        pool.approveYieldWithdrawal(tokenId);

        // ─── Second poke: executes yield withdrawal → emits HOLLAR back to
        //     the vault, then auto-requests principal withdrawal.
        vm.prank(KEEPER);
        vault.pokeDecentral(0);

        (, , , , , uint8 stateAfterSecondPoke) = vault.getPosition(0);
        assertEq(
            stateAfterSecondPoke,
            3,
            "position is PrincipalWithdrawalRequested after yield executed"
        );

        // Vault should now hold some HOLLAR (the yield) — it's "idle".
        uint256 idleAfterYield = vault.getIdleHollar();
        assertGt(idleAfterYield, 0, "vault has idle HOLLAR after yield exec");

        // ─── Decentral admin approves principal ─────────────────────────
        vm.prank(ADMIN);
        pool.approvePrincipalWithdrawal(tokenId);

        // ─── Warp past the 1h principal-withdrawal delay ─────────────────
        vm.warp(block.timestamp + 1 hours + 1);

        // ─── Third poke: executes principal → idle HOLLAR jumps by 100
        //     and the vault auto-settles the queue using the now-available
        //     liquidity.
        vm.prank(KEEPER);
        vault.pokeDecentral(0);

        (, , , , , uint8 stateAfterPrincipal) = vault.getPosition(0);
        assertEq(stateAfterPrincipal, 4, "position is Redeemed");

        // Queue should now show our request as fully settled.
        (, uint256 reqAmount, uint256 settled, uint256 hollarOwed, ) = vault
            .getRedemptionRequest(reqId);
        assertEq(
            settled,
            reqAmount,
            "request fully settled after principal returns"
        );
        assertGt(hollarOwed, 0, "HOLLAR is owed to the user");

        // ─── User claims via ERC-7540 redeem ─────────────────────────────
        uint256 userBalanceBefore = hollar.balanceOf(USER);
        vm.prank(USER);
        uint256 hollarReceived = vault.redeem(settled, USER, USER);

        assertEq(
            hollar.balanceOf(USER) - userBalanceBefore,
            hollarReceived,
            "HOLLAR transferred to user matches redeem return"
        );
        // The user should end up with at least their original deposit back
        // (principal). Yield went to the vault as protocol revenue / TVL
        // growth; not all is paid out per-redemption.
        assertGe(
            hollar.balanceOf(USER),
            DEPOSIT,
            "user got at least their principal back"
        );
    }

    /// Cancel path: queued redemption is cancelled before any settlement,
    /// freed hDCL goes back to the user's wallet (vault-only mode — no
    /// auto-resupply since there's no Aave layer here).
    function test_CancelBeforeSettlement() public {
        vm.startPrank(USER);
        hollar.approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, USER);
        uint256 reqId = vault.requestRedeem(shares, USER, USER);
        vm.stopPrank();

        // Vault has the escrowed hDCL; user has 0.
        assertEq(vault.balanceOf(USER), 0, "user hDCL escrowed");

        vm.prank(USER);
        vault.cancelRedeem(reqId);

        // Cancel returns the un-settled portion (here: 100%) to the user.
        assertEq(
            vault.balanceOf(USER),
            shares,
            "all hDCL returned after cancel"
        );

        (, , , , bool active) = vault.getRedemptionRequest(reqId);
        assertFalse(active, "request marked inactive after cancel");
    }

    /// Maturity-but-no-claim sanity: position matures and settles into the
    /// vault's idle balance, but the user hasn't requested a redemption.
    /// The vault should reinvest the proceeds into a fresh Decentral
    /// position (above min reinvest threshold).
    function test_MatureWithoutRedeemTriggersReinvest() public {
        vm.startPrank(USER);
        hollar.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, USER);
        vm.stopPrank();

        (uint256 tokenId, , , , , ) = vault.getPosition(0);

        // Mature + drive state machine to Redeemed (same steps as the happy
        // path but without a queued redemption).
        vm.warp(block.timestamp + 60 days + 1);
        vm.prank(KEEPER);
        vault.pokeDecentral(0);

        vm.prank(ADMIN);
        pool.approveYieldWithdrawal(tokenId);
        vm.prank(KEEPER);
        vault.pokeDecentral(0);

        vm.prank(ADMIN);
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(KEEPER);
        vault.pokeDecentral(0);

        // Drains idle HOLLAR back into Decentral via reinvest. Reinvest is
        // gated on `idleHollar >= minReinvestAmount` (10 HOLLAR default) and
        // only fires inside `pokeQueue`'s no-progress branch — `pokeDecentral`
        // doesn't trigger it directly.
        assertGt(
            vault.getIdleHollar(),
            vault.minReinvestAmount(),
            "idle HOLLAR > min reinvest threshold"
        );
        vm.prank(KEEPER);
        vault.pokeQueue();

        // Position 0 closed; reinvestment should have opened position 1.
        assertEq(vault.getPositionCount(), 2, "reinvested into a new position");

        (, , , , , uint8 newState) = vault.getPosition(1);
        assertEq(newState, 0, "new position is Active");
    }
}
