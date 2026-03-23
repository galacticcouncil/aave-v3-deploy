// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IPoolToken {
    struct TokenInfo {
        address pool;
        uint256 principalAmount;
        uint256 principalRedeemed;
        uint256 rewardDebt;
        uint256 createdAt;
        uint256 lastYieldPayoutTime;
    }

    event TokenMinted(
        address indexed owner,
        address indexed pool,
        uint256 indexed tokenId,
        uint256 principalAmount,
        uint256 initialRewardDebt
    );
    event RewardDebtUpdated(uint256 indexed tokenId, uint256 newRewardDebt);
    event LastYieldPayoutTimeUpdated(
        uint256 indexed tokenId,
        uint256 newTimestamp
    );
    event PrincipalRedemptionRecorded(
        uint256 indexed tokenId,
        uint256 principalRedeemedDelta,
        uint256 newPrincipalRedeemed
    );
    event TokenBurned(uint256 indexed tokenId);
    event BaseURISet(string newBaseURI);

    function initialize(
        string memory _name,
        string memory _symbol,
        string memory initialBaseURI,
        address _initialAdmin
    ) external;

    function setBaseURI(string memory baseURI_) external;

    function registerPool(address _poolAddress) external;

    function unregisterPool(address _poolAddress) external;

    function mint(
        address _to,
        uint256 _principalAmount,
        address _pool,
        uint256 _initialRewardDebt
    ) external returns (uint256);

    function recordPrincipalRedemption(
        uint256 _tokenId,
        uint256 _principalRedeemedDelta
    ) external;

    function updateRewardDebt(
        uint256 _tokenId,
        uint256 _newRewardDebt
    ) external;

    function updateLastYieldPayoutTime(
        uint256 _tokenId,
        uint256 _newTimestamp
    ) external;

    function burn(uint256 _tokenId) external;

    function adminSetTokenTimestamps(
        uint256 tokenId,
        uint256 createdAt,
        uint256 lastPayout
    ) external;

    function getTokenInfo(
        uint256 _tokenId
    ) external view returns (TokenInfo memory);

    function isPoolRegistered(
        address _poolAddress
    ) external view returns (bool);

    function tokenURI(uint256 tokenId) external view returns (string memory);

    function POOL_ROLE() external view returns (bytes32);

    function BURNER_ROLE() external view returns (bytes32);

    function ADMIN_ROLE() external view returns (bytes32);

    function UPGRADER_ROLE() external view returns (bytes32);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
