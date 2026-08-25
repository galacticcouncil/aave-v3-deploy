// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

contract Events {
    event Deposited(address indexed user, uint256 hollarAmount, uint256 bilMinted, uint256 decentalAmount, uint256 tokenId);
    event QueueClearedOnDeposit(uint256 hollarUsedForQueue, uint256 bilBurned);
    event RedemptionRequested(uint256 indexed requestId, address indexed user, uint256 bilAmount);
    event RedemptionCancelled(uint256 indexed requestId, uint256 bilReturned);
    event RedemptionFulfilled(uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 bilBurned);
    event RedemptionPartiallyFulfilled(uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 bilBurned);
    event Reinvested(uint256 hollarAmount, uint256 tokenId);
    event PositionProcessed(uint256 indexed positionIndex, uint256 tokenId, uint8 newState);
    event PositionRedeemed(uint256 indexed positionIndex, uint256 tokenId, uint256 yieldReceived, uint256 principalReceived);
    event DepositsPaused();
    event DepositsUnpaused();
    event TvlCapUpdated(uint256 newCap);
    event MinReinvestAmountUpdated(uint256 newAmount);
    event MinRedeemAmountUpdated(uint256 newAmount);
    event OracleUpdated(address indexed oracle);
}
