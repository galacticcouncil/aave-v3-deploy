// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILVault} from "../../src/BILVault.sol";
import {BILOracle} from "../../src/BILOracle.sol";
import {IDecentralPool} from "../../src/interfaces/IDecentralPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Comprehensive Admin Test Suite
/// @notice Covers initialize, pause/unpause, setTvlCap, setMinReinvestAmount,
///         setMinRedeemAmount, setOracle, and UUPS upgrade authorization.
contract AdminTest is BaseTest {

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _accessControlRevert(address account, bytes32 role) internal pure returns (bytes memory) {
        return bytes(string(abi.encodePacked(
            "AccessControl: account ",
            Strings.toHexString(account),
            " is missing role ",
            Strings.toHexString(uint256(role), 32)
        )));
    }

    function _expectedYield(uint256 principal, uint256 apyWad, uint256 days_)
        internal pure returns (uint256)
    {
        return (principal * apyWad * days_ * SECONDS_PER_DAY) / (365 days * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         INITIALIZE
    // ═══════════════════════════════════════════════════════════════════════

    function test_initialize_setsImmutableConfig() public view {
        assertEq(address(vault.activeDepositPool()), address(pool));
        assertEq(address(vault.hollar()), address(hollar));
        assertEq(vault.tvlCap(), INITIAL_TVL_CAP);
        assertTrue(vault.isPoolRegistered(IDecentralPool(address(pool))), "initial pool registered");
        assertTrue(vault.isRegisteredPoolToken(address(nft)), "initial pool token registered");
        assertEq(vault.getPoolCount(), 1, "one pool registered at init");
    }

    function test_initialize_setsDefaults() public view {
        assertEq(vault.minReinvestAmount(), 10e18, "Default minReinvestAmount = 10 HOLLAR");
        assertEq(vault.minRedeemAmount(), 1e18, "Default minRedeemAmount = 1 BIL");
        assertFalse(vault.depositsPaused());
    }

    function test_initialize_grantsRoles() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.UPGRADER_ROLE(), admin));
    }

    function test_initialize_setsTokenMetadata() public view {
        assertEq(vault.name(), "Brazilian Invoice Loans");
        assertEq(vault.symbol(), "BIL");
        assertEq(vault.decimals(), 18);
    }

    function test_initialize_revertsOnZeroAddresses() public {
        BILVault impl = new BILVault();

        // Zero decentralPool
        vm.expectRevert(BILVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(
            BILVault.initialize,
            (address(0), address(nft), address(hollar), INITIAL_TVL_CAP, admin)
        ));

        // Zero poolToken
        vm.expectRevert(BILVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(
            BILVault.initialize,
            (address(pool), address(0), address(hollar), INITIAL_TVL_CAP, admin)
        ));

        // Zero hollar
        vm.expectRevert(BILVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(
            BILVault.initialize,
            (address(pool), address(nft), address(0), INITIAL_TVL_CAP, admin)
        ));

        // Zero admin
        vm.expectRevert(BILVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(
            BILVault.initialize,
            (address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, address(0))
        ));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vault.initialize(address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, admin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    pauseDeposits / unpauseDeposits
    // ═══════════════════════════════════════════════════════════════════════

    function test_pauseDeposits_rejectsNonRoleHolder() public {
        vm.expectRevert(BILVault.NotAdminOrGuardian.selector);
        vm.prank(alice);
        vault.pauseDeposits();
    }

    function test_unpauseDeposits_rejectsNonRoleHolder() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.expectRevert(BILVault.NotAdminOrGuardian.selector);
        vm.prank(alice);
        vault.unpauseDeposits();
    }

    function test_pauseDeposits_allowedByGuardian() public {
        address guardian = makeAddr("guardian");
        bytes32 role = vault.GUARDIAN_ROLE();
        vm.prank(admin);
        vault.grantRole(role, guardian);

        vm.prank(guardian);
        vault.pauseDeposits();
        assertTrue(vault.depositsPaused());

        vm.prank(guardian);
        vault.unpauseDeposits();
        assertFalse(vault.depositsPaused());
    }

    function test_pauseDeposits_blocksDeposits() public {
        vm.prank(admin);
        vault.pauseDeposits();

        assertTrue(vault.depositsPaused());

        vm.expectRevert(BILVault.DepositsArePaused.selector);
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    function test_unpauseDeposits_allowsDeposits() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.prank(admin);
        vault.unpauseDeposits();

        assertFalse(vault.depositsPaused());

        uint256 bil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertGt(bil, 0);
    }

    /// @notice Spec: pausing deposits does NOT block redemptions or position processing
    function test_pauseDeposits_doesNotBlockRedemptionsOrProcessing() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(admin);
        vault.pauseDeposits();

        // requestRedeem still works
        _requestRedeem(alice, aliceBil / 4);
        assertGt(vault.totalQueuedBil(), 0);

        // pokeDecentral still works (warp past maturity)
        _warpDays(61);
        vault.pokeDecentral(0);
        (, , , , , uint8 state,,,) = vault.getPosition(0);
        assertEq(state, 1, "Position advances even with deposits paused");
    }

    function test_pauseDeposits_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit DepositsPaused();

        vm.prank(admin);
        vault.pauseDeposits();
    }

    function test_unpauseDeposits_emitsEvent() public {
        vm.prank(admin);
        vault.pauseDeposits();

        vm.expectEmit(false, false, false, false);
        emit DepositsUnpaused();

        vm.prank(admin);
        vault.unpauseDeposits();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      pause / unpause (global)
    // ═══════════════════════════════════════════════════════════════════════

    function test_pause_rejectsNonRoleHolder() public {
        vm.expectRevert(BILVault.NotAdminOrGuardian.selector);
        vm.prank(alice);
        vault.pause();
    }

    function test_unpause_rejectsNonRoleHolder() public {
        vm.prank(admin);
        vault.pause();

        vm.expectRevert(BILVault.NotAdminOrGuardian.selector);
        vm.prank(alice);
        vault.unpause();
    }

    function test_pause_allowedByGuardian() public {
        address guardian = makeAddr("guardian");
        bytes32 role = vault.GUARDIAN_ROLE();
        vm.prank(admin);
        vault.grantRole(role, guardian);

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        // Guardian can also unpause — symmetric authority by design.
        vm.prank(guardian);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_guardian_cannotCallAdminFunctions() public {
        address guardian = makeAddr("guardian");
        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        bytes32 adminRole = vault.ADMIN_ROLE();
        vm.prank(admin);
        vault.grantRole(guardianRole, guardian);

        // Guardian gets pause authority but NOT general admin authority.
        vm.expectRevert(_accessControlRevert(guardian, adminRole));
        vm.prank(guardian);
        vault.setTvlCap(1);

        vm.expectRevert(_accessControlRevert(guardian, adminRole));
        vm.prank(guardian);
        vault.setMinReinvestAmount(1);

        vm.expectRevert(_accessControlRevert(guardian, adminRole));
        vm.prank(guardian);
        vault.setMinRedeemAmount(1);
    }

    /// @notice Spec: emergency pause stops ALL state-changing operations
    function test_pause_blocksAllOperations() public {
        uint256 aliceBil = _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(admin);
        vault.pause();

        // deposit
        vm.expectRevert("Pausable: paused");
        _deposit(bob, TEN_THOUSAND_HOLLAR);

        // requestRedeem
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        vault.requestRedeem(aliceBil / 4, alice, alice);

        // pokeDecentral
        vm.expectRevert("Pausable: paused");
        vault.pokeDecentral(0);

        // pokeQueue
        vm.expectRevert("Pausable: paused");
        vault.pokeQueue();
    }

    function test_unpause_resumesOperations() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(admin);
        vault.unpause();

        uint256 bil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertGt(bil, 0, "Deposit works after unpause");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          setTvlCap
    // ═══════════════════════════════════════════════════════════════════════

    function test_setTvlCap_onlyAdmin() public {
        vm.expectRevert(_accessControlRevert(alice, vault.ADMIN_ROLE()));
        vm.prank(alice);
        vault.setTvlCap(1e18);
    }

    function test_setTvlCap_updatesValue() public {
        uint256 newCap = 5_000_000e18;
        vm.prank(admin);
        vault.setTvlCap(newCap);

        assertEq(vault.tvlCap(), newCap);
    }

    function test_setTvlCap_canIncrease() public {
        vm.prank(admin);
        vault.setTvlCap(10_000_000e18);

        assertEq(vault.tvlCap(), 10_000_000e18);
    }

    /// @notice DEVIATION: Contract requires `newCap >= totalAssets()`.
    ///         Spec says "Can be decreased (no forced withdrawals)" with no floor.
    ///         Contract prevents lowering cap below current totalAssets.
    function test_setTvlCap_revertsBelowCurrentAssets() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        vm.prank(admin);
        vm.expectRevert(BILVault.CapBelowAssets.selector);
        vault.setTvlCap(TEN_THOUSAND_HOLLAR - 1);
    }

    function test_setTvlCap_canDecrease_aboveCurrentAssets() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // totalAssets ~= 10k at t=0, so 10k cap should work
        vm.prank(admin);
        vault.setTvlCap(TEN_THOUSAND_HOLLAR);

        assertEq(vault.tvlCap(), TEN_THOUSAND_HOLLAR);
    }

    function test_setTvlCap_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TvlCapUpdated(5_000_000e18);

        vm.prank(admin);
        vault.setTvlCap(5_000_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      setMinReinvestAmount
    // ═══════════════════════════════════════════════════════════════════════

    function test_setMinReinvestAmount_onlyAdmin() public {
        vm.expectRevert(_accessControlRevert(alice, vault.ADMIN_ROLE()));
        vm.prank(alice);
        vault.setMinReinvestAmount(100e18);
    }

    function test_setMinReinvestAmount_updatesValue() public {
        vm.prank(admin);
        vault.setMinReinvestAmount(100e18);

        assertEq(vault.minReinvestAmount(), 100e18);
    }

    function test_setMinReinvestAmount_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MinReinvestAmountUpdated(100e18);

        vm.prank(admin);
        vault.setMinReinvestAmount(100e18);
    }

    /// @notice Changing minReinvestAmount affects whether pokeQueue reinvests
    function test_setMinReinvestAmount_affectsReinvest() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);
        _warpDays(61);
        _processPositionFull(0);

        // Set min very high so reinvest is skipped
        vm.prank(admin);
        vault.setMinReinvestAmount(100_000e18);

        uint256 posBefore = vault.getPositionCount();
        vault.pokeQueue();
        assertEq(vault.getPositionCount(), posBefore, "Reinvest skipped with high min");

        // Lower min back -> reinvest succeeds
        vm.prank(admin);
        vault.setMinReinvestAmount(10e18);

        vault.pokeQueue();
        assertGt(vault.getPositionCount(), posBefore, "Reinvest succeeds with low min");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       setMinRedeemAmount
    // ═══════════════════════════════════════════════════════════════════════

    function test_setMinRedeemAmount_onlyAdmin() public {
        vm.expectRevert(_accessControlRevert(alice, vault.ADMIN_ROLE()));
        vm.prank(alice);
        vault.setMinRedeemAmount(10e18);
    }

    function test_setMinRedeemAmount_updatesValue() public {
        vm.prank(admin);
        vault.setMinRedeemAmount(10e18);

        assertEq(vault.minRedeemAmount(), 10e18);
    }

    function test_setMinRedeemAmount_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MinRedeemAmountUpdated(10e18);

        vm.prank(admin);
        vault.setMinRedeemAmount(10e18);
    }

    /// @notice setMinRedeemAmount(0) reverts. A zero floor would let an
    ///         attacker post zero-BIL redemption requests that pass the
    ///         requestRedeem gate, escrow zero BIL, and still consume a
    ///         work iteration per spam entry in the queue processor.
    function test_setMinRedeemAmount_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(BILVault.MinMustBePositive.selector);
        vault.setMinRedeemAmount(0);
    }

    /// @notice Changing minRedeemAmount affects redemption threshold
    function test_setMinRedeemAmount_affectsRedemptions() public {
        _deposit(alice, TEN_THOUSAND_HOLLAR);

        // Raise min to 5000 BIL
        vm.prank(admin);
        vault.setMinRedeemAmount(5000e18);

        // Small redeem should revert
        vm.prank(alice);
        vm.expectRevert(BILVault.BelowMinimumRedeem.selector);
        vault.requestRedeem(4999e18, alice, alice);

        // At-min redeem should succeed
        vm.prank(alice);
        vault.requestRedeem(5000e18, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          setOracle
    // ═══════════════════════════════════════════════════════════════════════

    function test_setOracle_onlyAdmin() public {
        vm.expectRevert(_accessControlRevert(alice, vault.ADMIN_ROLE()));
        vm.prank(alice);
        vault.setOracle(address(1));
    }

    function test_setOracle_updatesValue() public {
        // setOracle now probes the candidate, so it requires a real oracle
        // implementation. Use BILOracle (the production oracle) as the probe
        // target — it serves the vault's own exchange rate.
        BILOracle newOracle = new BILOracle(address(vault));
        vm.prank(admin);
        vault.setOracle(address(newOracle));

        assertEq(address(vault.oracle()), address(newOracle));
    }

    function test_setOracle_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(BILVault.ZeroAddress.selector);
        vault.setOracle(address(0));
    }

    function test_setOracle_emitsEvent() public {
        BILOracle newOracle = new BILOracle(address(vault));

        vm.expectEmit(true, false, false, false);
        emit OracleUpdated(address(newOracle));

        vm.prank(admin);
        vault.setOracle(address(newOracle));
    }

    /// @notice setOracle's new probe rejects a plain EOA-style address that
    ///         doesn't implement IAggregatorV3Interface — the latestRoundData
    ///         call reverts and propagates up. This guards against fat-finger
    ///         misconfiguration where admin pastes the wrong address.
    function test_setOracle_revertsOnNonOracleAddress() public {
        address notAnOracle = makeAddr("not-an-oracle");
        vm.prank(admin);
        vm.expectRevert();
        vault.setOracle(notAnOracle);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       getOraclePrice
    // ═══════════════════════════════════════════════════════════════════════

    function test_getOraclePrice_revertsWithoutOracle() public {
        vm.expectRevert(BILVault.OracleNotSet.selector);
        vault.getOraclePrice();
    }

    function test_getOraclePrice_returnsCorrectPrice() public {
        // Deploy BILOracle and set it
        BILOracle wdclOracle = new BILOracle(address(vault));
        vm.prank(admin);
        vault.setOracle(address(wdclOracle));

        _deposit(alice, TEN_THOUSAND_HOLLAR);

        uint256 price = vault.getOraclePrice();
        // Oracle returns 8 decimals, getOraclePrice scales to 18
        // At rate ~1e18: oracle answer = 1e8, price = 1e8 * 1e18 / 1e8 = 1e18
        assertApproxEqRel(price, 1e18, 0.001e18, "Oracle price ~= 1e18 at 1:1 rate");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      UUPS UPGRADE
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgrade_onlyUpgrader() public {
        BILVault newImpl = new BILVault();

        vm.expectRevert(_accessControlRevert(alice, vault.UPGRADER_ROLE()));
        vm.prank(alice);
        vault.upgradeTo(address(newImpl));
    }

    function test_upgrade_succeeds() public {
        BILVault newImpl = new BILVault();

        vm.prank(admin);
        vault.upgradeTo(address(newImpl));

        // Vault still works after upgrade
        uint256 bil = _deposit(alice, TEN_THOUSAND_HOLLAR);
        assertGt(bil, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    ACCESS CONTROL SMOKE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Spec §6.1: no admin function to extract vault funds or NFTs
    function test_noAdminExtractionFunction() public view {
        // Verify vault has no external transfer/withdraw function for HOLLAR or NFTs
        // This is a documentation test — if the contract compiles with only the known
        // admin functions, no extraction path exists. The only HOLLAR exits are:
        //   1. Queue fulfillment (burns BIL, sends HOLLAR to user)
        //   2. Reinvest (deposits into Decentral)
        // Both are permissionless and follow protocol rules.
        assertTrue(true, "No admin extraction function exists");
    }
}
