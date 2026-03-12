// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockPoolToken} from "./MockPoolToken.sol";

contract MockDecentralPool {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_INVESTMENT_PERIOD = 60 days;
    uint256 public constant PRINCIPAL_WITHDRAWAL_DELAY = 48 hours;

    // ── Immutables & state ───────────────────────────────────────────────
    IERC20 public immutable hollar;
    MockPoolToken public immutable poolToken;
    uint256 public fixedAPYWad;

    // ── Position tracking ────────────────────────────────────────────────
    struct MockPosition {
        address depositor;
        uint256 principal;
        uint256 depositTime;
        uint256 lastYieldPayoutTime;
        bool yieldRequested;
        bool yieldApproved;
        bool principalRequested;
        bool principalApproved;
        uint256 principalAvailableTime;
        bool burned;
    }

    mapping(uint256 => MockPosition) public mockPositions;

    // ── Constructor ──────────────────────────────────────────────────────
    constructor(address _hollar, address _poolToken, uint256 _apyWad) {
        hollar = IERC20(_hollar);
        poolToken = MockPoolToken(_poolToken);
        fixedAPYWad = _apyWad;
    }

    // ── Deposit ──────────────────────────────────────────────────────────
    function deposit(uint256 amount) external returns (uint256) {
        hollar.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tokenId = poolToken.safeMint(msg.sender);

        mockPositions[tokenId] = MockPosition({
            depositor: msg.sender,
            principal: amount,
            depositTime: block.timestamp,
            lastYieldPayoutTime: block.timestamp,
            yieldRequested: false,
            yieldApproved: false,
            principalRequested: false,
            principalApproved: false,
            principalAvailableTime: 0,
            burned: false
        });

        return tokenId;
    }

    // ── Yield withdrawal ─────────────────────────────────────────────────
    function requestYieldWithdrawal(uint256 tokenId) external {
        MockPosition storage pos = mockPositions[tokenId];
        require(!pos.burned, "Position burned");
        require(
            block.timestamp >= pos.depositTime + MIN_INVESTMENT_PERIOD,
            "Min investment period not met"
        );
        pos.yieldRequested = true;
    }

    function approveYieldWithdrawal(uint256 tokenId) external {
        MockPosition storage pos = mockPositions[tokenId];
        require(pos.yieldRequested, "Yield not requested");
        pos.yieldApproved = true;
    }

    function executeYieldWithdrawal(uint256 tokenId) external {
        MockPosition storage pos = mockPositions[tokenId];
        require(!pos.burned, "Position burned");
        require(pos.yieldApproved, "Yield not approved");

        uint256 elapsed = block.timestamp - pos.lastYieldPayoutTime;
        uint256 yieldAmount = (pos.principal * fixedAPYWad * elapsed) / SECONDS_PER_YEAR / 1e18;

        pos.lastYieldPayoutTime = block.timestamp;
        pos.yieldRequested = false;
        pos.yieldApproved = false;

        address owner = poolToken.ownerOf(tokenId);
        hollar.safeTransfer(owner, yieldAmount);
    }

    // ── Principal withdrawal ─────────────────────────────────────────────
    function requestPrincipalWithdrawal(uint256 tokenId) external {
        MockPosition storage pos = mockPositions[tokenId];
        require(!pos.burned, "Position burned");
        pos.principalRequested = true;
        pos.principalAvailableTime = block.timestamp + PRINCIPAL_WITHDRAWAL_DELAY;
    }

    function approvePrincipalWithdrawal(uint256 tokenId) external {
        MockPosition storage pos = mockPositions[tokenId];
        require(pos.principalRequested, "Principal not requested");
        pos.principalApproved = true;
    }

    function executePrincipalWithdrawal(uint256 tokenId) external {
        MockPosition storage pos = mockPositions[tokenId];
        require(!pos.burned, "Position burned");
        require(pos.principalApproved, "Principal not approved");
        require(
            block.timestamp >= pos.principalAvailableTime,
            "Principal delay not elapsed"
        );

        uint256 principal = pos.principal;
        pos.burned = true;

        address owner = poolToken.ownerOf(tokenId);
        hollar.safeTransfer(owner, principal);
        poolToken.burn(tokenId);
    }

    // ── Admin helpers for tests ──────────────────────────────────────────
    function setAPY(uint256 newAPY) external {
        fixedAPYWad = newAPY;
    }
}
