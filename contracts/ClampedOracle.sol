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
/// The contract returns primary, clamped to within ±maxDiffBps of secondary.
/// This caps the influence of a manipulated primary at maxDiffBps from
/// secondary, while still letting liquidations proceed (at a lagged price)
/// during real volatility instead of DoS'ing the AaveOracle.
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

        return int256(_clampToBand(uint256(pAns), uint256(sAns)));
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

    /// @dev Clamps `p` into [s*(1-N/MAX_BPS), s*(1+N/MAX_BPS)]. Boundary
    /// values are returned unmodified.
    function _clampToBand(
        uint256 p,
        uint256 s
    ) internal view returns (uint256) {
        uint256 lower = (s * (MAX_BPS - maxDiffBps)) / MAX_BPS;
        uint256 upper = (s * (MAX_BPS + maxDiffBps)) / MAX_BPS;
        if (p < lower) return lower;
        if (p > upper) return upper;
        return p;
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
