// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IERC7540Operator — operator approval for async vault operations
interface IERC7540Operator {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setOperator(address operator, bool approved) external;
    function isOperator(address controller, address operator) external view returns (bool);
}

/// @title IERC7540Redeem — async redemption flow per ERC-7540
interface IERC7540Redeem {
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
}
