// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import "@aave/periphery-v3/contracts/misc/interfaces/IEACAggregatorProxy.sol";

/**
 * Minimal Chainlink-compatible oracle that returns a constant price
 * set by the owner. Used on lark test chains where the real EMA oracle
 * path is not populated.
 *
 * MAINNET: never use. The prod stHDX oracle is USDOracleAdapter
 * (stHDX/HDX EMA × HDX/USD chainlink).
 */
contract FixedPriceOracle is IEACAggregatorProxy {
    uint8 public constant decimals = 8;

    int256 private _price;
    address public owner;

    event PriceUpdated(int256 oldPrice, int256 newPrice);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    constructor(int256 initialPrice, address owner_) {
        require(owner_ != address(0), "zero owner");
        _price = initialPrice;
        owner = owner_;
        emit PriceUpdated(0, initialPrice);
        emit OwnerChanged(address(0), owner_);
    }

    function setPrice(int256 newPrice) external {
        require(msg.sender == owner, "not owner");
        int256 old = _price;
        _price = newPrice;
        emit PriceUpdated(old, newPrice);
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        require(newOwner != address(0), "zero owner");
        address old = owner;
        owner = newOwner;
        emit OwnerChanged(old, newOwner);
    }

    function latestAnswer() external view override returns (int256) {
        return _price;
    }

    function latestTimestamp() external view override returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external view override returns (uint256) {
        return 1;
    }

    function getAnswer(uint256) external view override returns (int256) {
        return _price;
    }

    function getTimestamp(uint256) external view override returns (uint256) {
        return block.timestamp;
    }
}
