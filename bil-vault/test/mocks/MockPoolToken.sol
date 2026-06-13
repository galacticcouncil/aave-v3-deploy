// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IPoolToken} from "../../src/interfaces/IPoolToken.sol";

/// @notice Faithful mock of the Decentral PoolToken ERC-721 contract.
/// @dev Mirrors the real PoolToken: per-token TokenInfo, POOL_ROLE-gated mint/update,
///      and BURNER_ROLE-gated burn. Simplified to a single-pool allowlist for test use.
contract MockPoolToken is ERC721 {
    // ── Token Info (matches real PoolToken) ────────────────────────────────

    struct TokenInfo {
        address pool;
        uint256 principalAmount;
        uint256 principalRedeemed;
        uint256 rewardDebt;
        uint256 createdAt;
        uint256 lastYieldPayoutTime;
    }

    mapping(uint256 => TokenInfo) private _tokenInfo;
    uint256 private _nextTokenId = 1;

    // ── Pool Registry ──────────────────────────────────────────────────────

    mapping(address => bool) public registeredPools;

    // ── Constructor ────────────────────────────────────────────────────────

    constructor() ERC721("Decentral LP Token", "dLPt") {}

    // ── Access ─────────────────────────────────────────────────────────────

    modifier onlyPool() {
        require(registeredPools[msg.sender], "MockPoolToken: caller is not a registered pool");
        _;
    }

    function registerPool(address _pool) external {
        registeredPools[_pool] = true;
    }

    function unregisterPool(address _pool) external {
        registeredPools[_pool] = false;
    }

    function isPoolRegistered(address _pool) external view returns (bool) {
        return registeredPools[_pool];
    }

    // ── Mint (called by DecentralPool.deposit) ─────────────────────────────

    /// @dev Matches IPoolToken.mint signature used by the real DecentralPool._deposit()
    function mint(
        address _to,
        uint256 _principalAmount,
        address _pool,
        uint256 _initialRewardDebt
    ) external onlyPool returns (uint256) {
        uint256 tokenId = _nextTokenId++;

        _tokenInfo[tokenId] = TokenInfo({
            pool: _pool,
            principalAmount: _principalAmount,
            principalRedeemed: 0,
            rewardDebt: _initialRewardDebt,
            createdAt: block.timestamp,
            lastYieldPayoutTime: block.timestamp
        });

        _safeMint(_to, tokenId);
        return tokenId;
    }

    // ── Mutations (called by DecentralPool during withdrawals) ─────────────

    function recordPrincipalRedemption(
        uint256 _tokenId,
        uint256 _principalRedeemedDelta
    ) external onlyPool {
        _tokenInfo[_tokenId].principalRedeemed += _principalRedeemedDelta;
    }

    function updateRewardDebt(
        uint256 _tokenId,
        uint256 _newRewardDebt
    ) external onlyPool {
        _tokenInfo[_tokenId].rewardDebt = _newRewardDebt;
    }

    function updateLastYieldPayoutTime(
        uint256 _tokenId,
        uint256 _newTimestamp
    ) external onlyPool {
        _tokenInfo[_tokenId].lastYieldPayoutTime = _newTimestamp;
    }

    // ── Burn ───────────────────────────────────────────────────────────────

    function burn(uint256 _tokenId) external onlyPool {
        delete _tokenInfo[_tokenId];
        _burn(_tokenId);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function getTokenInfo(uint256 _tokenId) external view returns (TokenInfo memory) {
        return _tokenInfo[_tokenId];
    }

    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }
}
