// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IPoolToken} from "./IPoolToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDecentralPool {
    struct PrincipalWithdrawalRequest {
        uint256 amount;
        uint256 requestTimestamp;
        uint256 availableTimestamp;
        bool exists;
        bool approved;
    }

    struct YieldWithdrawalRequest {
        uint256 amount;
        uint256 requestTimestamp;
        bool exists;
        bool approved;
    }

    event Deposited(
        address indexed investor,
        uint256 indexed tokenId,
        uint256 principalAmount
    );
    event LiquidityAdded(address indexed provider, uint256 amount);
    event RewardAccrued(
        uint256 timestamp,
        uint256 timeElapsed,
        uint256 rewardAccrued,
        uint256 newCumulativeRewardPerShare
    );
    event YieldWithdrawalRequested(
        address indexed investor,
        uint256 indexed tokenId,
        uint256 amount
    );
    event YieldWithdrawalApproved(
        address indexed approver,
        uint256 indexed tokenId,
        uint256 amount
    );
    event YieldWithdrawn(
        address indexed investor,
        uint256 indexed tokenId,
        uint256 amount
    );
    event PrincipalWithdrawalRequested(
        address indexed investor,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 availableTimestamp
    );
    event PrincipalWithdrawalApproved(
        address indexed approver,
        uint256 indexed tokenId,
        uint256 amount
    );
    event PrincipalWithdrawn(
        address indexed investor,
        uint256 indexed tokenId,
        uint256 amount
    );
    event TokenBurned(address indexed investor, uint256 indexed tokenId);
    event PoolShutdown(address indexed caller, uint256 timestamp);
    event InvestmentLimitsSet(uint256 minimumAmount, uint256 maximumAmount);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed repayer, uint256 amount);

    function initialize(
        address _factoryAddress,
        address _poolTokenAddress,
        address _stablecoinAddress,
        uint256 _fixedAPYBasisPoints,
        uint256 _paymentFrequencyDays,
        uint256 _minimumInvestmentPeriodDays,
        uint256 _principalWithdrawalDelayHours,
        uint256 _minimumInvestmentAmount,
        uint256 _maximumInvestmentAmount,
        address _initialAdmin
    ) external;

    function deposit(uint256 _amount) external returns (uint256 tokenId);

    function depositWithPermit(
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 tokenId);

    function requestYieldWithdrawal(uint256 _tokenId) external;

    function executeYieldWithdrawal(uint256 _tokenId) external;

    function requestPrincipalWithdrawal(uint256 _tokenId) external;

    function executePrincipalWithdrawal(uint256 _tokenId) external;

    function borrow(uint256 _amount) external;

    function repay(uint256 _amount) external;

    function addLiquidity(uint256 _amount) external;

    function approvePrincipalWithdrawal(uint256 _tokenId) external;

    function batchApprovePrincipalWithdrawals(
        uint256[] calldata _tokenIds
    ) external;

    function approveYieldWithdrawal(uint256 _tokenId) external;

    function batchApproveYieldWithdrawals(
        uint256[] calldata _tokenIds
    ) external;

    function setInvestmentLimits(
        uint256 _minimumInvestmentAmount,
        uint256 _maximumInvestmentAmount
    ) external;

    function pause() external;

    function unpause() external;

    function shutdownPool() external;

    function adminMintMigratedPositionsBatch(
        address[] calldata investors,
        uint256[] calldata principals,
        uint256 createdAt
    ) external;

    function pendingRewards(uint256 _tokenId) external view returns (uint256);

    function getPoolInfo()
        external
        view
        returns (
            uint256 _totalPrincipalShares,
            uint256 _fixedAPYWad,
            uint256 _paymentFrequencySeconds,
            uint256 _minimumInvestmentPeriodSeconds,
            uint256 _principalWithdrawalDelaySeconds,
            uint256 _minimumInvestmentAmount,
            uint256 _maximumInvestmentAmount,
            uint256 _lastUpdateTime,
            uint256 _cumulativeRewardPerShare,
            address _stablecoinAddress,
            uint8 _stablecoinDecimals,
            address _poolTokenAddress,
            bool _isShutdown,
            address _factoryAddress
        );

    function getPrincipalWithdrawalRequest(
        uint256 _tokenId
    )
        external
        view
        returns (
            uint256 amount,
            uint256 requestTimestamp,
            uint256 availableTimestamp,
            bool exists,
            bool approved
        );

    function getYieldWithdrawalRequest(
        uint256 _tokenId
    )
        external
        view
        returns (
            uint256 amount,
            uint256 requestTimestamp,
            bool exists,
            bool approved
        );

    function factoryAddress() external view returns (address);

    function poolToken() external view returns (IPoolToken);

    function stablecoin() external view returns (IERC20);

    function stablecoinAddress() external view returns (address);

    function fixedAPYWad() external view returns (uint256);

    function fixedDailyRateWad() external view returns (uint256);

    function paymentFrequencySeconds() external view returns (uint256);

    function minimumInvestmentPeriodSeconds() external view returns (uint256);

    function principalWithdrawalDelaySeconds() external view returns (uint256);

    function minimumInvestmentAmount() external view returns (uint256);

    function maximumInvestmentAmount() external view returns (uint256);

    function cumulativeRewardPerShare() external view returns (uint256);

    function lastUpdateTime() external view returns (uint256);

    function totalPrincipalShares() external view returns (uint256);

    function isShutdown() external view returns (bool);

    function ADMIN_ROLE() external view returns (bytes32);

    function APPROVER_ROLE() external view returns (bytes32);

    function LIQUIDITY_PROVIDER_ROLE() external view returns (bytes32);

    function BORROWER_ROLE() external view returns (bytes32);

    function UPGRADER_ROLE() external view returns (bytes32);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
