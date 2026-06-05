// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test stand-in for the Hydration Augustus-backed ISwapper (REQ-SWAP).
///         Swaps at a configurable fixed price (WAD), assuming the contract is
///         pre-funded with the output token. Mirrors the value-stable PRIME↔HOLLAR
///         relationship by default (1:1).
contract MockSwapper is ISwapper {
    using SafeERC20 for IERC20;

    uint256 public priceWad = 1e18; // tokenOut per tokenIn, 1e18 = 1:1

    function setPrice(uint256 p) external {
        priceWad = p;
    }

    function sell(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * priceWad) / 1e18;
        require(amountOut >= minOut, "MockSwapper: minOut");
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function buy(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, bytes calldata)
        external
        override
        returns (uint256 amountIn)
    {
        amountIn = (amountOut * 1e18) / priceWad;
        require(amountIn <= maxIn, "MockSwapper: maxIn");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
