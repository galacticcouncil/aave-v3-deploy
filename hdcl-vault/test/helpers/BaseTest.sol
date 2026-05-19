// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HDCLVault} from "../../src/HDCLVault.sol";
import {MockHollar} from "../mocks/MockHollar.sol";
import {MockDecentralPool} from "../mocks/MockDecentralPool.sol";
import {MockPoolToken} from "../mocks/MockPoolToken.sol";
import {Constants} from "./Constants.sol";
import {Events} from "./Events.sol";

contract BaseTest is Test, Constants, Events {
    HDCLVault public vault;
    MockHollar public hollar;
    MockDecentralPool public pool;
    MockPoolToken public nft;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public keeper = makeAddr("keeper");

    function setUp() public virtual {
        // Deploy mocks
        hollar = new MockHollar();
        nft = new MockPoolToken();
        pool = new MockDecentralPool(address(hollar), address(nft), APY_18_PERCENT);

        // Allow pool to mint/burn NFTs
        nft.registerPool(address(pool));

        // Fund mock pool with HOLLAR for yield payouts
        hollar.mint(address(pool), 10_000_000e18);

        // Deploy vault via proxy
        HDCLVault implementation = new HDCLVault();
        bytes memory initData = abi.encodeCall(
            HDCLVault.initialize,
            (address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = HDCLVault(address(proxy));

        // Mint HOLLAR to test users
        hollar.mint(alice, 100_000e18);
        hollar.mint(bob, 100_000e18);
        hollar.mint(charlie, 50_000e18);

        // Users approve vault
        vm.prank(alice);
        hollar.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        hollar.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        hollar.approve(address(vault), type(uint256).max);
    }

    // ─── Test Helpers ───

    function _deposit(address user, uint256 amount) internal returns (uint256 hdclMinted) {
        vm.prank(user);
        return vault.deposit(amount, user);
    }

    function _requestRedeem(address user, uint256 amount) internal returns (uint256 requestId) {
        vm.prank(user);
        return vault.requestRedeem(amount, user, user);
    }

    /// @dev Claim every settled share the user currently has across the queue.
    ///      Useful in tests that previously asserted on the push-model post-state
    ///      (HOLLAR delivered inside pokeQueue) — under pull, the claim is a
    ///      separate step the user must invoke. Iterates from 0 since settled
    ///      entries can live below queueHead.
    function _claimAll(address user) internal returns (uint256 assets) {
        uint256 totalSettled;
        uint256 tail = vault.getRedemptionQueueLength();
        for (uint256 i = 0; i < tail; i++) {
            (address u,, uint256 hdclSettled,,) = vault.getRedemptionRequest(i);
            if (u == user) totalSettled += hdclSettled;
        }
        if (totalSettled == 0) return 0;
        vm.prank(user);
        return vault.redeem(totalSettled, user, user);
    }

    function _processPositionFull(uint256 positionIndex) internal {
        // Step 1: Active -> YieldWithdrawalRequested (must be past maturity)
        vault.pokeDecentral(positionIndex);

        // Step 2: Approve yield on mock, then execute yield withdrawal
        (uint256 tokenId,,,,, ) = vault.getPosition(positionIndex);
        pool.approveYieldWithdrawal(tokenId);
        vault.pokeDecentral(positionIndex);

        // Step 3: YieldClaimed -> PrincipalWithdrawalRequested happens in the same
        //         processPosition call that claimed yield. Now we need to approve
        //         principal and warp past the 48-hour delay.
        pool.approvePrincipalWithdrawal(tokenId);
        vm.warp(block.timestamp + FORTY_EIGHT_HOURS + 1);
        vault.pokeDecentral(positionIndex);
    }

    function _warpDays(uint256 days_) internal {
        vm.warp(block.timestamp + days_ * SECONDS_PER_DAY);
    }
}
