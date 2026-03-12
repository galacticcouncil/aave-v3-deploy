// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockPoolToken is ERC721 {
    uint256 private _nextTokenId = 1;
    address public pool;

    constructor() ERC721("Decentral LP Token", "dLPt") {}

    function setPool(address _pool) external {
        pool = _pool;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "Not pool");
        _;
    }

    function safeMint(address to) external onlyPool returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    function burn(uint256 tokenId) external onlyPool {
        _burn(tokenId);
    }
}
