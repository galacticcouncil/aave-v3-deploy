// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IClampedOracle} from "./interfaces/IClampedOracle.sol";
import {AggregatorInterface} from "./dependencies/chainlink/AggregatorInterface.sol";
import {IHydraChainlinkOracle} from "./dependencies/hydra-chainlink/IHydraChainlinkOracle.sol";

/// @notice Threat model:
/// - Primary is an external push-based feed (DIA / Chainlink-style). It is the
///   more manipulation-prone side: a bad round or a successful attack on the
///   updater can move it sharply in a single update.
/// - Secondary is Hydration's on-chain 10-min stableswap/Omnipool TWAP
///   precompile. The TWAP smoothing already makes it costly to move; we treat
///   it as the manipulation-resistant anchor.
///
/// Resolution order for latestAnswer:
///  1. If primary's latest round is inside the secondary band, return it.
///  2. Otherwise try primary's immediately preceding round. If that round is
///     inside the band, return it. A single-round primary attack is rejected
///     entirely -- the reported price does not move.
///  3. Otherwise (previous round also out of band or unavailable) clamp the
///     latest primary value to the secondary band edge. Preserves liveness
///     during real volatility at the cost of allowing the original ±maxDiffBps
///     influence per the clamp design.
///
/// Trade-off accepted: a sustained TWAP manipulation on the secondary can
/// drag the reported price by its drift ± maxDiffBps. This is deemed cheaper
/// to defend against here than the bad-debt risk of halting liquidations
/// during a real crash.
///
/// Fallbacks:
/// - Primary unavailable -> revert. Secondary alone is not trusted.
/// - Secondary unavailable -> return primary unclamped (lose the bound,
///   preserve liveness).
contract ClampedOracle is IClampedOracle {
    uint256 public constant MAX_BPS = 10_000;

    AggregatorInterface private immutable primaryAgg;
    IHydraChainlinkOracle private immutable secondaryAgg;

    uint256 public immutable override maxDiffBps;

    constructor(
        address primaryFeed,
        address secondaryFeed,
        uint256 maxDiffBps_
    ) {
        if (primaryFeed == address(0) || secondaryFeed == address(0))
            revert InvalidFeed();
        if (maxDiffBps_ > MAX_BPS) revert InvalidBps();

        primaryAgg = AggregatorInterface(primaryFeed);
        secondaryAgg = IHydraChainlinkOracle(secondaryFeed);
        maxDiffBps = maxDiffBps_;

        emit ClampedOracleInitialized(primaryFeed, secondaryFeed, maxDiffBps_);
    }

    function primary() external view override returns (address) {
        return address(primaryAgg);
    }

    function secondary() external view override returns (address) {
        return address(secondaryAgg);
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function latestAnswer() external view override returns (int256) {
        (bool pOk, int256 pAns) = _tryLatestAnswerPrimary();
        if (!pOk) revert NoValidPrice();

        (bool sOk, int256 sAns) = _tryLatestAnswerSecondary();
        if (!sOk) return pAns;

        uint256 P = uint256(pAns);
        uint256 S = uint256(sAns);
        (uint256 lower, uint256 upper) = _bandOf(S);

        if (P >= lower && P <= upper) return pAns;

        // Latest primary outside band -- try the previous round before
        // clamping. A single-round manipulation falls off here.
        (bool prevOk, int256 prevAns) = _tryPrimaryPreviousRound();
        if (prevOk) {
            uint256 PPrev = uint256(prevAns);
            if (PPrev >= lower && PPrev <= upper) return prevAns;
        }

        // Previous round also out of band (or unavailable): clamp latest.
        if (P < lower) return int256(lower);
        return int256(upper);
    }

    function latestTimestamp() external view override returns (uint256) {
        return primaryAgg.latestTimestamp();
    }

    function latestRound() external view override returns (uint256) {
        return primaryAgg.latestRound();
    }

    function getAnswer(
        uint256 roundId
    ) external view override returns (int256) {
        (bool pOk, int256 pAns) = _tryGetAnswerPrimary(roundId);
        if (!pOk) revert NoValidPrice();

        (bool sOk, int256 sAns) = _tryGetAnswerSecondary(roundId);
        if (!sOk) return pAns;

        return int256(_clampToBand(uint256(pAns), uint256(sAns)));
    }

    function getTimestamp(
        uint256 roundId
    ) external view override returns (uint256) {
        return primaryAgg.getTimestamp(roundId);
    }

    function _bandOf(
        uint256 s
    ) internal view returns (uint256 lower, uint256 upper) {
        lower = (s * (MAX_BPS - maxDiffBps)) / MAX_BPS;
        upper = (s * (MAX_BPS + maxDiffBps)) / MAX_BPS;
    }

    function _clampToBand(
        uint256 p,
        uint256 s
    ) internal view returns (uint256) {
        (uint256 lower, uint256 upper) = _bandOf(s);
        if (p < lower) return lower;
        if (p > upper) return upper;
        return p;
    }

    /// @dev Returns primary's answer at `latestRound() - 1`, treating any
    /// revert, missing round, or non-positive answer as unavailable.
    function _tryPrimaryPreviousRound()
        internal
        view
        returns (bool ok, int256 ans)
    {
        uint256 lr;
        try primaryAgg.latestRound() returns (uint256 r) {
            lr = r;
        } catch {
            return (false, 0);
        }
        if (lr == 0) return (false, 0);
        return _tryGetAnswerPrimary(lr - 1);
    }

    function _tryLatestAnswerPrimary()
        internal
        view
        returns (bool ok, int256 ans)
    {
        try primaryAgg.latestAnswer() returns (int256 a) {
            if (a <= 0) return (false, 0);
            return (true, a);
        } catch {
            return (false, 0);
        }
    }

    function _tryLatestAnswerSecondary()
        internal
        view
        returns (bool ok, int256 ans)
    {
        try secondaryAgg.latestAnswer() returns (int256 a) {
            if (a <= 0) return (false, 0);
            return (true, a);
        } catch {
            return (false, 0);
        }
    }

    function _tryGetAnswerPrimary(
        uint256 roundId
    ) internal view returns (bool ok, int256 ans) {
        try primaryAgg.getAnswer(roundId) returns (int256 a) {
            if (a <= 0) return (false, 0);
            return (true, a);
        } catch {
            return (false, 0);
        }
    }

    function _tryGetAnswerSecondary(
        uint256 roundId
    ) internal view returns (bool ok, int256 ans) {
        try secondaryAgg.getAnswer(roundId) returns (int256 a) {
            if (a <= 0) return (false, 0);
            return (true, a);
        } catch {
            return (false, 0);
        }
    }
}
