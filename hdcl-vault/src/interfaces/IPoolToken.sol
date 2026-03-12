// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IPoolToken
/// @notice Minimal interface for Decentral Protocol's position NFT token.
/// @dev Extends IERC721. The vault uses `ownerOf()` and `balanceOf()` inherited
///      from IERC721 to verify position ownership. No additional functions are needed.
interface IPoolToken is IERC721 {
    // No additional functions needed beyond IERC721.
}
