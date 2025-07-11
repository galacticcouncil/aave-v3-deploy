// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {AggregatorV3Interface} from "./dependencies/chainlink/AggregatorV3Interface.sol";
import {Ownable} from "./dependencies/openzeppelin/contracts/Ownable.sol";

contract ManagedOracle is AggregatorV3Interface, Ownable {

    uint8 public constant decimals = 8;

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    RoundData private currentRound;
    string private _description;
    uint256 private _version;

    event PriceUpdated(uint80 indexed roundId, int256 answer, uint256 timestamp);

    constructor(
        string memory description_,
        uint256 version_,
        address initialOwner,
        int256 initialPrice
    ) Ownable() {
        _description = description_;
        _version = version_;

        transferOwnership(initialOwner);

        currentRound = RoundData({
            roundId: 1,
            answer: initialPrice,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: 1
        });

        emit PriceUpdated(1, initialPrice, block.timestamp);
    }

    function setPrice(int256 price) external onlyOwner {
        currentRound.roundId++;
        currentRound.answer = price;
        currentRound.startedAt = block.timestamp;
        currentRound.updatedAt = block.timestamp;
        currentRound.answeredInRound = currentRound.roundId;

        emit PriceUpdated(currentRound.roundId, price, block.timestamp);
    }

    function latestRoundData()
    external
    view
    override
    returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    )
    {
        return (
            currentRound.roundId,
            currentRound.answer,
            currentRound.startedAt,
            currentRound.updatedAt,
            currentRound.answeredInRound
        );
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    function getRoundData(uint80 _roundId)
    external
    view
    override
    returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    )
    {
        // For simplicity, always return latest round data, historical data is not needed
        return this.latestRoundData();
    }

    function latestAnswer() external view returns (int256) {
        return currentRound.answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return currentRound.updatedAt;
    }

    function latestRound() external view returns (uint256) {
        return currentRound.roundId;
    }

    function getAnswer(uint256 roundId) external view returns (int256) {
        // For simplicity, always return latest round data, historical data is not needed
        return currentRound.answer;
    }

    function getTimestamp(uint256 roundId) external view returns (uint256) {
        // For simplicity, always return latest round data, historical data is not needed
        return currentRound.updatedAt;
    }
}
