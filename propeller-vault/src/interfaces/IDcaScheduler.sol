// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IDcaScheduler
/// @notice Seam over Hydration's native DCA (pallet-DCA), reached from EVM via
///         the `0x0401` dispatch precompile. Schedules **unbounded** DCA orders
///         that route through the Substrate router + the Aave trade-executor
///         (PoolType::Aave), so the trades fold the Aave supply/withdraw in:
///           - deploy:  HOLLAR ─▶ aPRIME   (HOLLAR→PRIME→aPRIME; ends in Aave supply)
///           - unwind:  aPRIME ─▶ HOLLAR   (aPRIME→PRIME→HOLLAR; starts with Aave withdraw)
///
/// @dev    REQ-DCA. Like REQ-SWAP, the concrete dispatch-encoding adapter is a
///         dependency to be provided/built; SubLoop builds against this seam and
///         tests inject a mock. Tranche sizing + cadence are set per order so
///         each tranche stays within the HF-safe sliver.
interface IDcaScheduler {
    /// @notice Start (or top up) an unbounded HOLLAR→aPRIME deploy order whose
    ///         output collateral lands in `beneficiary`'s Aave position.
    /// @param amountPerTranche HOLLAR spent per execution
    /// @param totalBudget      HOLLAR budget to add to the order
    /// @return orderId         pallet-DCA schedule id
    function scheduleDeploy(address beneficiary, uint256 amountPerTranche, uint256 totalBudget)
        external
        returns (uint256 orderId);

    /// @notice Start an unbounded aPRIME→HOLLAR unwind order pulling collateral
    ///         from `beneficiary`'s Aave position, delivering HOLLAR back to it.
    function scheduleUnwind(address beneficiary, uint256 amountPerTranche, uint256 totalCollateral)
        external
        returns (uint256 orderId);

    /// @notice Cancel a live order.
    function cancel(uint256 orderId) external;

    /// @notice Remaining (unspent) budget on an order.
    function remaining(uint256 orderId) external view returns (uint256);
}
