// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDcaScheduler} from "../../src/interfaces/IDcaScheduler.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPool} from "./MockPool.sol";

/// @notice Test stand-in for REQ-DCA (pallet-DCA + Aave trade-executor route).
///         A deploy order is funded with HOLLAR up front; `executeDeploy`
///         simulates one tranche: HOLLAR→PRIME (value-stable 1:1, decimal-
///         adjusted) then supply to the pool → aPRIME lands in the beneficiary's
///         position. Execution is test-driven (no scheduler), so tests advance
///         the ramp tranche by tranche.
contract MockDcaScheduler is IDcaScheduler {
    struct Order {
        address beneficiary;
        uint256 tranche;
        uint256 budget; // remaining HOLLAR
        bool isDeploy;
        bool active;
    }

    IAavePool public immutable pool;
    MockERC20 public immutable hollar;
    MockERC20 public immutable prime;
    uint256 internal constant HOLLAR_TO_PRIME = 1e12; // 18dp → 6dp

    mapping(uint256 => Order) public orders;
    mapping(address => uint256) public deployOrderOf; // beneficiary → stable deploy order
    mapping(address => uint256) public unwindOrderOf; // beneficiary → stable unwind order
    uint256 public nextId = 1;

    constructor(address _pool, address _hollar, address _prime) {
        pool = IAavePool(_pool);
        hollar = MockERC20(_hollar);
        prime = MockERC20(_prime);
    }

    function scheduleDeploy(address beneficiary, uint256 amountPerTranche, uint256 totalBudget)
        external
        override
        returns (uint256 orderId)
    {
        hollar.transferFrom(msg.sender, address(this), totalBudget);
        orderId = deployOrderOf[beneficiary];
        if (orderId == 0 || !orders[orderId].active) {
            orderId = nextId++;
            deployOrderOf[beneficiary] = orderId;
            orders[orderId] = Order(beneficiary, amountPerTranche, totalBudget, true, true);
        } else {
            orders[orderId].budget += totalBudget;
            orders[orderId].tranche = amountPerTranche;
        }
    }

    function scheduleUnwind(address beneficiary, uint256 amountPerTranche, uint256 totalCollateral)
        external
        override
        returns (uint256 orderId)
    {
        orderId = unwindOrderOf[beneficiary];
        if (orderId == 0 || !orders[orderId].active) {
            orderId = nextId++;
            unwindOrderOf[beneficiary] = orderId;
            orders[orderId] = Order(beneficiary, amountPerTranche, totalCollateral, false, true);
        } else {
            orders[orderId].budget += totalCollateral;
            orders[orderId].tranche = amountPerTranche;
        }
    }

    /// @notice Test helper: execute one unwind tranche — withdraw HF-safe aPRIME
    ///         from the beneficiary's position, swap PRIME→HOLLAR (value-stable,
    ///         decimal-adjusted), deliver HOLLAR to the beneficiary.
    function executeUnwind(uint256 orderId) external returns (uint256 hollarOut) {
        Order storage o = orders[orderId];
        require(o.active && !o.isDeploy, "MockDca: bad order");
        uint256 safe = MockPool(address(pool)).maxWithdrawable(o.beneficiary, address(prime));
        uint256 amt = o.tranche > o.budget ? o.budget : o.tranche;
        if (amt > safe) amt = safe;
        require(amt > 0, "MockDca: no safe sliver");
        o.budget -= amt;

        // withdraw PRIME (on behalf) → swap PRIME→HOLLAR → deliver to beneficiary
        MockPool(address(pool)).mockWithdrawTo(address(prime), amt, o.beneficiary, address(this));
        prime.burn(address(this), amt);
        hollarOut = amt * HOLLAR_TO_PRIME; // 6dp → 18dp, $1
        hollar.mint(o.beneficiary, hollarOut);
    }

    function cancel(uint256 orderId) external override {
        orders[orderId].active = false;
    }

    function remaining(uint256 orderId) external view override returns (uint256) {
        return orders[orderId].budget;
    }

    /// @notice Test helper: execute one deploy tranche (HOLLAR→PRIME→supply).
    function executeDeploy(uint256 orderId) external returns (uint256 primeSupplied) {
        Order storage o = orders[orderId];
        require(o.active && o.isDeploy, "MockDca: bad order");
        uint256 spend = o.tranche > o.budget ? o.budget : o.tranche;
        require(spend > 0, "MockDca: empty");
        o.budget -= spend;

        // HOLLAR→PRIME (value-stable, decimal-adjusted); mock by minting PRIME.
        primeSupplied = spend / HOLLAR_TO_PRIME;
        prime.mint(address(this), primeSupplied);
        prime.approve(address(pool), primeSupplied);
        pool.supply(address(prime), primeSupplied, o.beneficiary, 0);
    }

    /// @notice Test helper: drain a deploy order to completion in one call.
    function executeDeployFully(uint256 orderId) external {
        Order storage o = orders[orderId];
        while (o.active && o.budget > 0) {
            uint256 spend = o.tranche > o.budget ? o.budget : o.tranche;
            o.budget -= spend;
            uint256 primeOut = spend / HOLLAR_TO_PRIME;
            prime.mint(address(this), primeOut);
            prime.approve(address(pool), primeOut);
            pool.supply(address(prime), primeOut, o.beneficiary, 0);
        }
    }
}
