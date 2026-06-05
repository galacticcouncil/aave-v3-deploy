// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ISwapper
/// @notice Propeller's swap seam. The production implementation is backed by
///         the Hydration Augustus (`IParaSwapAugustus`, the Aave-aligned swap
///         interface) which routes the opaque calldata to the Substrate router
///         (pallet-route-executor) over the Omnipool / 2-Pool-PRIME stableswap.
///
/// @dev    REQ-SWAP. Not yet deployed on Hydration mainnet — tests inject a
///         MockSwapper. Kept as a thin internal interface so the real Augustus
///         adapter drops in behind it without touching vault/loop logic.
interface ISwapper {
    /// @notice Exact-in swap. Pulls `amountIn` of `tokenIn` from msg.sender,
    ///         returns at least `minOut` of `tokenOut` to msg.sender.
    /// @param route Opaque router path (encoded off-chain; passed through to
    ///              the Augustus / route-executor).
    function sell(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata route
    ) external returns (uint256 amountOut);

    /// @notice Exact-out swap. Pulls up to `maxIn` of `tokenIn`, returns exactly
    ///         `amountOut` of `tokenOut`; refunds unused `tokenIn`.
    function buy(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn,
        bytes calldata route
    ) external returns (uint256 amountIn);
}

/// @notice The Aave-standard swap interface the Hydration Augustus implements.
///         Documented here for reference; the ISwapper impl wraps it.
interface IParaSwapAugustus {
    function getTokenTransferProxy() external view returns (address);
}
