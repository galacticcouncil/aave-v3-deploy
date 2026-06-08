// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockPool} from "./MockPool.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Test stand-in for the Hydration Augustus-backed ISwapper (REQ-SWAP).
///         Prices cross-asset swaps off the MockPool's oracle prices (+ decimals),
///         the way the real router would. Mints the output / burns the input
///         (mock tokens) so no pre-funding is needed.
contract MockSwapper is ISwapper {
    using SafeERC20 for IERC20;

    MockPool public immutable pool;
    uint256 public haircutBps; // test knob: under-deliver vs oracle-fair (basis points)

    constructor(address _pool) {
        pool = MockPool(_pool);
    }

    /// @dev test-only: make `sell` return less than oracle-fair, to exercise a
    ///      lossy/malicious fill against the vault's compound oracle floor.
    function setHaircut(uint256 bps) external {
        haircutBps = bps;
    }

    function _usd(address t, uint256 amt) internal view returns (uint256) {
        (uint256 p, uint8 d) = pool.assetPrice(t);
        return (amt * p) / (10 ** d); // 18dp USD
    }

    function _fromUsd(address t, uint256 usd) internal view returns (uint256) {
        (uint256 p, uint8 d) = pool.assetPrice(t);
        return (usd * (10 ** d)) / p; // native units
    }

    function sell(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenIn).burn(address(this), amountIn);
        amountOut = _fromUsd(tokenOut, _usd(tokenIn, amountIn));
        if (haircutBps > 0) amountOut = (amountOut * (10_000 - haircutBps)) / 10_000;
        require(amountOut >= minOut, "MockSwapper: minOut");
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }

    function buy(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, bytes calldata)
        external
        override
        returns (uint256 amountIn)
    {
        amountIn = _fromUsd(tokenIn, _usd(tokenOut, amountOut));
        require(amountIn <= maxIn, "MockSwapper: maxIn");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenIn).burn(address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}
