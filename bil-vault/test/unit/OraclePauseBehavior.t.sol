// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../helpers/BaseTest.sol";
import {BILOracle} from "../../src/BILOracle.sol";
import {BILVault} from "../../src/BILVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Oracle Pause Behavior — Regression Coverage
/// @notice Verifies that BILOracle continues to serve the current exchange rate
///         while the vault is paused. Pre-fix, `latestRoundData` and `getRoundData`
///         reverted on pause, which could have cascaded into downstream lending
///         markets (blocked liquidations, unprice-able collateral, bad debt).
contract OraclePauseBehaviorTest is BaseTest {
    BILOracle public oracle;

    function setUp() public override {
        super.setUp();
        oracle = new BILOracle(address(vault));
        vm.prank(admin);
        vault.setOracle(address(oracle));
        // Seed the vault so totalSupply > 0 and exchangeRate is meaningful.
        _deposit(alice, TEN_THOUSAND_HOLLAR);
    }

    // ─── Helper: simulates a downstream consumer reading the price feed ────
    function _consumerReadPrice() internal view returns (uint256 price18d) {
        (, int256 answer,,,) = oracle.latestRoundData();
        // Answer is 8 decimals; scale to 18 decimals.
        return uint256(answer) * 1e10;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   CORE: oracle works through pause
    // ═══════════════════════════════════════════════════════════════════════

    function test_oracle_servesRateWhilePaused() public {
        (, int256 answerBefore,,,) = oracle.latestRoundData();

        vm.prank(admin);
        vault.pause();

        // No revert
        (, int256 answerWhilePaused,,,) = oracle.latestRoundData();

        // Same rate (or off by at most a wei from time-progress between calls).
        assertApproxEqAbs(
            uint256(answerWhilePaused),
            uint256(answerBefore),
            1,
            "oracle answer must be readable while paused"
        );
    }

    function test_oracle_returnsValidTimestampsWhilePaused() public {
        vm.warp(1_800_000_000);

        vm.prank(admin);
        vault.pause();

        (, , uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(startedAt, block.timestamp, "startedAt = block.timestamp");
        assertEq(updatedAt, block.timestamp, "updatedAt = block.timestamp");
    }

    function test_oracle_answerNonZeroWhilePaused() public {
        vm.prank(admin);
        vault.pause();

        (, int256 answer,,,) = oracle.latestRoundData();
        assertGt(answer, 0, "answer must be > 0 even when paused");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   getRoundData PERMISSIVE BEHAVIOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Permissive: getRoundData accepts ANY roundId and returns current data.
    function test_getRoundData_anyRoundIdReturnsCurrentData() public view {
        // Try a few wildly different round IDs.
        uint80[] memory roundIds = new uint80[](4);
        roundIds[0] = 0;
        roundIds[1] = 1;
        roundIds[2] = type(uint80).max;
        roundIds[3] = uint80(block.number);

        (, int256 latestAnswer,,,) = oracle.latestRoundData();

        for (uint256 i = 0; i < roundIds.length; i++) {
            (, int256 answer,, uint256 updatedAt,) = oracle.getRoundData(roundIds[i]);
            assertEq(answer, latestAnswer, "getRoundData should return same data regardless of roundId");
            assertEq(updatedAt, block.timestamp, "updatedAt should always be current");
        }
    }

    /// @notice getRoundData works while paused too.
    function test_getRoundData_worksWhilePaused() public {
        vm.prank(admin);
        vault.pause();

        (, int256 answer,, uint256 updatedAt,) = oracle.getRoundData(42);
        assertGt(answer, 0, "getRoundData should serve a positive answer while paused");
        assertEq(updatedAt, block.timestamp, "timestamp current while paused");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   PAUSE/UNPAUSE LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Oracle keeps appreciating across pause/unpause boundaries.
    function test_oracle_appreciatesThroughPauseLifecycle() public {
        (, int256 a0,,,) = oracle.latestRoundData();

        // Warp some time
        _warpDays(15);
        (, int256 a1,,,) = oracle.latestRoundData();
        assertGt(a1, a0, "rate grows before pause");

        // Pause
        vm.prank(admin);
        vault.pause();

        // Warp during pause; oracle still works and rate keeps growing
        _warpDays(15);
        (, int256 a2,,,) = oracle.latestRoundData();
        assertGt(a2, a1, "rate grows even while paused (math is still valid)");

        // Unpause
        vm.prank(admin);
        vault.unpause();

        _warpDays(15);
        (, int256 a3,,,) = oracle.latestRoundData();
        assertGt(a3, a2, "rate grows after unpause");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   DOWNSTREAM CONSUMER SCENARIO (Aave-like price-feed integration)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pre-fix, this scenario would have caused bad debt: vault paused
    ///         during an emergency, downstream lending market couldn't price BIL,
    ///         couldn't liquidate underwater positions, accumulated bad debt.
    ///         Post-fix, the oracle stays alive and consumers can still operate.
    function test_downstreamConsumer_canPriceCollateralWhilePaused() public {
        uint256 priceBefore = _consumerReadPrice();
        assertGt(priceBefore, 0);

        // Vault pauses for emergency
        vm.prank(admin);
        vault.pause();

        // Consumer (e.g., Aave) tries to read price for a liquidation check.
        // Pre-fix: this would revert; liquidations would be blocked.
        // Post-fix: returns a valid price.
        uint256 priceWhilePaused = _consumerReadPrice();
        assertGt(priceWhilePaused, 0, "consumer can still price collateral");
        assertApproxEqAbs(priceWhilePaused, priceBefore, 1e10, "price stable across pause");
    }

    /// @notice Repeated pause/unpause should not affect oracle behavior at all.
    function test_oracle_idempotentAcrossMultiplePauseCycles() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(admin);
            vault.pause();

            (, int256 a,,,) = oracle.latestRoundData();
            assertGt(a, 0);

            vm.prank(admin);
            vault.unpause();

            (, int256 b,,,) = oracle.latestRoundData();
            assertGt(b, 0);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   getOraclePrice (vault wrapper) also works while paused
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The vault's own `getOraclePrice` view (which calls into the oracle)
    ///         must also succeed while the vault is paused.
    function test_vaultGetOraclePrice_worksWhilePaused() public {
        vm.prank(admin);
        vault.pause();

        uint256 price = vault.getOraclePrice();
        assertGt(price, 0, "vault.getOraclePrice must work while paused");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //   ZERO-SUPPLY EDGE CASE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Even on a freshly-deployed paused vault with no deposits, the
    ///         oracle returns the canonical 1:1 rate — no revert.
    function test_oracle_freshVaultPausedReturnsOneToOne() public {
        // Deploy a brand new vault with no deposits.
        BILVault impl = new BILVault();
        bytes memory initData = abi.encodeCall(
            BILVault.initialize,
            (address(pool), address(nft), address(hollar), INITIAL_TVL_CAP, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BILVault freshVault = BILVault(address(proxy));
        BILOracle freshOracle = new BILOracle(address(freshVault));

        // Pause the fresh vault
        vm.prank(admin);
        freshVault.pause();

        // Oracle still works; returns 1e8 (1:1 in 8 decimals).
        (, int256 answer,,,) = freshOracle.latestRoundData();
        assertEq(uint256(answer), 1e8, "fresh paused vault: 1:1 rate");
    }
}
