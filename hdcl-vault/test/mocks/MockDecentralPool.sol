// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockPoolToken} from "./MockPoolToken.sol";

/// @notice Faithful mock of the Decentral DecentralPool contract.
/// @dev Mirrors the real contract's deposit → yield request → yield execute →
///      principal request → principal execute lifecycle, including ownership checks,
///      approval gating, timing enforcement, and yield calculation.
contract MockDecentralPool {
    using SafeERC20 for IERC20;

    // ── Constants (match production values) ────────────────────────────────
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant REWARD_PRECISION = 1e27;

    // ── Configuration ──────────────────────────────────────────────────────
    IERC20 public immutable stablecoin;
    MockPoolToken public immutable poolToken;
    uint256 public fixedAPYWad;
    uint256 public minimumInvestmentAmount;
    uint256 public maximumInvestmentAmount;
    uint256 public paymentFrequencySeconds;

    uint256 private _minimumInvestmentPeriodSeconds;
    uint256 private _principalWithdrawalDelaySeconds;

    bool public isShutdown;
    bool public isPaused;

    // ── Reward accrual state ───────────────────────────────────────────────
    uint256 public cumulativeRewardPerShare;
    uint256 public lastUpdateTime;
    uint256 public totalPrincipalShares;

    // ── Per-token position tracking ────────────────────────────────────────
    struct MockPosition {
        address depositor;
        uint256 principal;
        uint256 depositTime;
        uint256 lastYieldPayoutTime;
        uint256 rewardDebt; // scaled by REWARD_PRECISION
    }

    mapping(uint256 => MockPosition) public mockPositions;

    // ── Withdrawal requests (mirrors real contract structs) ────────────────

    struct YieldWithdrawalRequest {
        uint256 amount;
        uint256 requestTimestamp;
        bool exists;
        bool approved;
    }

    struct PrincipalWithdrawalRequest {
        uint256 amount;
        uint256 requestTimestamp;
        uint256 availableTimestamp;
        bool exists;
        bool approved;
    }

    mapping(uint256 => YieldWithdrawalRequest) public yieldWithdrawalRequests;
    mapping(uint256 => PrincipalWithdrawalRequest) public principalWithdrawalRequests;

    // ── Constructor ────────────────────────────────────────────────────────

    constructor(
        address _stablecoin,
        address _poolToken,
        uint256 _apyWad
    ) {
        stablecoin = IERC20(_stablecoin);
        poolToken = MockPoolToken(_poolToken);
        fixedAPYWad = _apyWad;
        _minimumInvestmentPeriodSeconds = 60 days;
        _principalWithdrawalDelaySeconds = 48 hours;
        paymentFrequencySeconds = 1 days;
        minimumInvestmentAmount = 10e18; // 10 HOLLAR
        maximumInvestmentAmount = type(uint256).max;
        lastUpdateTime = block.timestamp;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                              DEPOSIT
    // ═════════════════════════════════════════════════════════════════════════

    function deposit(uint256 _amount) external returns (uint256 tokenId) {
        require(!isPaused, "Pool paused");
        require(!isShutdown, "Pool shutdown");
        require(_amount > 0, "Amount must be > 0");
        require(_amount >= minimumInvestmentAmount, "Below minimum investment");
        require(_amount <= maximumInvestmentAmount, "Above maximum investment");

        _updateRewardAccrual();

        uint256 initialRewardDebt = (_amount * cumulativeRewardPerShare);
        totalPrincipalShares += _amount;

        stablecoin.safeTransferFrom(msg.sender, address(this), _amount);

        tokenId = poolToken.mint(msg.sender, _amount, address(this), initialRewardDebt);

        mockPositions[tokenId] = MockPosition({
            depositor: msg.sender,
            principal: _amount,
            depositTime: block.timestamp,
            lastYieldPayoutTime: block.timestamp,
            rewardDebt: initialRewardDebt
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         YIELD WITHDRAWAL
    // ═════════════════════════════════════════════════════════════════════════

    function requestYieldWithdrawal(uint256 _tokenId) external {
        require(!isPaused, "Pool paused");
        require(!isShutdown, "Pool shutdown");
        require(poolToken.ownerOf(_tokenId) == msg.sender, "Not token owner");
        require(!yieldWithdrawalRequests[_tokenId].exists, "Yield request already pending");

        MockPosition storage pos = mockPositions[_tokenId];
        require(
            block.timestamp >= pos.lastYieldPayoutTime + paymentFrequencySeconds,
            "Payment frequency not met"
        );

        _updateRewardAccrual();

        uint256 totalEarned = pos.principal * cumulativeRewardPerShare;
        uint256 yieldToWithdraw = (totalEarned - pos.rewardDebt) / REWARD_PRECISION;
        require(yieldToWithdraw > 0, "No yield to withdraw");

        yieldWithdrawalRequests[_tokenId] = YieldWithdrawalRequest({
            amount: yieldToWithdraw,
            requestTimestamp: block.timestamp,
            exists: true,
            approved: false
        });
    }

    function executeYieldWithdrawal(uint256 _tokenId) external {
        require(!isPaused, "Pool paused");
        require(!isShutdown, "Pool shutdown");
        require(poolToken.ownerOf(_tokenId) == msg.sender, "Not token owner");

        YieldWithdrawalRequest storage req = yieldWithdrawalRequests[_tokenId];
        require(req.exists, "No yield request");
        require(req.approved, "Yield not approved");

        uint256 yieldAmount = req.amount;

        _updateRewardAccrual();

        MockPosition storage pos = mockPositions[_tokenId];
        pos.rewardDebt += yieldAmount * REWARD_PRECISION;
        pos.lastYieldPayoutTime = block.timestamp;
        poolToken.updateRewardDebt(_tokenId, pos.rewardDebt);
        poolToken.updateLastYieldPayoutTime(_tokenId, block.timestamp);

        delete yieldWithdrawalRequests[_tokenId];

        stablecoin.safeTransfer(msg.sender, yieldAmount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                       PRINCIPAL WITHDRAWAL
    // ═════════════════════════════════════════════════════════════════════════

    function requestPrincipalWithdrawal(uint256 _tokenId) external {
        require(!isPaused, "Pool paused");
        require(!isShutdown, "Pool shutdown");
        require(poolToken.ownerOf(_tokenId) == msg.sender, "Not token owner");
        require(!principalWithdrawalRequests[_tokenId].exists, "Principal request already pending");

        MockPosition storage pos = mockPositions[_tokenId];
        require(
            block.timestamp >= pos.depositTime + _minimumInvestmentPeriodSeconds,
            "Min investment period not met"
        );

        _updateRewardAccrual();

        uint256 availableTs = block.timestamp + _principalWithdrawalDelaySeconds;

        principalWithdrawalRequests[_tokenId] = PrincipalWithdrawalRequest({
            amount: pos.principal,
            requestTimestamp: block.timestamp,
            availableTimestamp: availableTs,
            exists: true,
            approved: false
        });
    }

    function executePrincipalWithdrawal(uint256 _tokenId) external {
        require(!isPaused, "Pool paused");
        require(poolToken.ownerOf(_tokenId) == msg.sender, "Not token owner");

        PrincipalWithdrawalRequest storage req = principalWithdrawalRequests[_tokenId];
        require(req.exists, "No principal request");
        require(req.approved, "Principal not approved");
        require(block.timestamp >= req.availableTimestamp, "Delay not elapsed");

        uint256 principal = req.amount;

        _updateRewardAccrual();
        totalPrincipalShares -= principal;

        poolToken.recordPrincipalRedemption(_tokenId, principal);

        delete principalWithdrawalRequests[_tokenId];
        delete mockPositions[_tokenId];

        stablecoin.safeTransfer(msg.sender, principal);
        poolToken.burn(_tokenId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                         APPROVAL (test helper)
    // ═════════════════════════════════════════════════════════════════════════

    function approveYieldWithdrawal(uint256 _tokenId) external {
        YieldWithdrawalRequest storage req = yieldWithdrawalRequests[_tokenId];
        require(req.exists, "No yield request");
        require(!req.approved, "Already approved");
        req.approved = true;
    }

    function approvePrincipalWithdrawal(uint256 _tokenId) external {
        PrincipalWithdrawalRequest storage req = principalWithdrawalRequests[_tokenId];
        require(req.exists, "No principal request");
        require(!req.approved, "Already approved");
        req.approved = true;
    }

    function batchApproveYieldWithdrawals(uint256[] calldata _tokenIds) external {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            YieldWithdrawalRequest storage req = yieldWithdrawalRequests[_tokenIds[i]];
            require(req.exists, "No yield request");
            req.approved = true;
        }
    }

    function batchApprovePrincipalWithdrawals(uint256[] calldata _tokenIds) external {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            PrincipalWithdrawalRequest storage req = principalWithdrawalRequests[_tokenIds[i]];
            require(req.exists, "No principal request");
            req.approved = true;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                          REWARD ACCRUAL
    // ═════════════════════════════════════════════════════════════════════════

    function _updateRewardAccrual() internal {
        if (totalPrincipalShares == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed == 0) return;

        uint256 rewardAccrued = (totalPrincipalShares * fixedAPYWad * elapsed) /
            (SECONDS_PER_YEAR * WAD);

        if (rewardAccrued > 0) {
            cumulativeRewardPerShare += (rewardAccrued * REWARD_PRECISION) / totalPrincipalShares;
        }

        lastUpdateTime = block.timestamp;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    // fixedAPYWad is a public state variable — auto-generates getter

    function minimumInvestmentPeriodSeconds() external view returns (uint256) {
        return _minimumInvestmentPeriodSeconds;
    }

    function principalWithdrawalDelaySeconds() external view returns (uint256) {
        return _principalWithdrawalDelaySeconds;
    }

    function pendingRewards(uint256 _tokenId) external view returns (uint256) {
        MockPosition storage pos = mockPositions[_tokenId];
        if (pos.principal == 0) return 0;

        uint256 currentCumulativeReward = cumulativeRewardPerShare;
        if (totalPrincipalShares > 0) {
            uint256 elapsed = block.timestamp - lastUpdateTime;
            uint256 rewardAccrued = (totalPrincipalShares * fixedAPYWad * elapsed) /
                (SECONDS_PER_YEAR * WAD);
            currentCumulativeReward += (rewardAccrued * REWARD_PRECISION) / totalPrincipalShares;
        }

        uint256 totalEarned = pos.principal * currentCumulativeReward;
        return (totalEarned - pos.rewardDebt) / REWARD_PRECISION;
    }

    function stablecoinAddress() external view returns (address) {
        return address(stablecoin);
    }

    function getYieldWithdrawalRequest(uint256 _tokenId)
        external
        view
        returns (uint256 amount, uint256 requestTimestamp, bool exists, bool approved)
    {
        YieldWithdrawalRequest storage req = yieldWithdrawalRequests[_tokenId];
        return (req.amount, req.requestTimestamp, req.exists, req.approved);
    }

    function getPrincipalWithdrawalRequest(uint256 _tokenId)
        external
        view
        returns (
            uint256 amount,
            uint256 requestTimestamp,
            uint256 availableTimestamp,
            bool exists,
            bool approved
        )
    {
        PrincipalWithdrawalRequest storage req = principalWithdrawalRequests[_tokenId];
        return (req.amount, req.requestTimestamp, req.availableTimestamp, req.exists, req.approved);
    }

    function getPoolInfo()
        external
        view
        returns (
            uint256 _totalPrincipalShares,
            uint256 _fixedAPYWad,
            uint256 _paymentFrequencySeconds,
            uint256 _minimumInvestmentPeriodSecs,
            uint256 _principalWithdrawalDelaySecs,
            uint256 _minimumInvestmentAmt,
            uint256 _maximumInvestmentAmt,
            uint256 _lastUpdateTime,
            uint256 _cumulativeRewardPerShare,
            address _stablecoinAddress,
            uint8 _stablecoinDecimals,
            address _poolTokenAddress,
            bool _isShutdown,
            address _factoryAddress
        )
    {
        return (
            totalPrincipalShares,
            fixedAPYWad,
            paymentFrequencySeconds,
            _minimumInvestmentPeriodSeconds,
            _principalWithdrawalDelaySeconds,
            minimumInvestmentAmount,
            maximumInvestmentAmount,
            lastUpdateTime,
            cumulativeRewardPerShare,
            address(stablecoin),
            18,
            address(poolToken),
            isShutdown,
            address(0) // no factory in mock
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //                       TEST ADMIN HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    function setAPY(uint256 _newAPY) external {
        fixedAPYWad = _newAPY;
    }

    function setMinimumInvestmentAmount(uint256 _amount) external {
        minimumInvestmentAmount = _amount;
    }

    function setMaximumInvestmentAmount(uint256 _amount) external {
        maximumInvestmentAmount = _amount;
    }

    function setPaused(bool _paused) external {
        isPaused = _paused;
    }

    function setShutdown(bool _shutdown) external {
        isShutdown = _shutdown;
    }

    function setMinimumInvestmentPeriodSeconds(uint256 _seconds) external {
        _minimumInvestmentPeriodSeconds = _seconds;
    }

    function setPrincipalWithdrawalDelaySeconds(uint256 _seconds) external {
        _principalWithdrawalDelaySeconds = _seconds;
    }

    /// @dev Fund the pool with stablecoin so it can pay out yield/principal
    function fundPool(uint256 _amount) external {
        stablecoin.safeTransferFrom(msg.sender, address(this), _amount);
    }
}
