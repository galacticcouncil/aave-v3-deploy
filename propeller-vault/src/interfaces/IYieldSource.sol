// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IYieldSource
/// @notice The socket a `CollateralVault` plugs a yield strategy into. The vault
///         hands over borrowed HOLLAR and receives *shares* priced off the
///         source's live NAV; it never learns what the source does with them.
///
/// @dev    **This is the pluggable boundary.** Nothing here mentions PRIME, Aave,
///         leverage, or a health factor — those belong to a specific
///         *implementation* (`ISubLoop`), not to the contract between vault and
///         strategy. A different venue (an ERC-4626/7540 wrapper, an RWA vault)
///         implements this interface directly and the vault needs no change.
///
///         Deposits and withdrawals are **async by contract**: `deposit` only
///         credits shares (the source ramps in at its own pace), and
///         `requestUnwind` only records a target — the source frees HOLLAR
///         gradually and the vault `pullFreed()`s it as it accrues. A synchronous
///         source satisfies this trivially by freeing everything on the first pull.
interface IYieldSource {
    // ── vault → source: put money in ──────────────────────────────────────

    /// @notice Take `hollarAmount` from the calling vault and credit it shares at
    ///         the source's current NAV. The HOLLAR need not be deployed by the
    ///         time this returns — only accounted.
    function deposit(uint256 hollarAmount) external returns (uint256 shares);

    // ── vault → source: take money out (async) ────────────────────────────

    /// @notice Begin releasing `shares` of the calling vault's equity. Burns the
    ///         shares and grows the source's release target; the HOLLAR is freed
    ///         over blocks. Returns an id for tracking.
    function requestUnwind(uint256 shares) external returns (uint256 unwindId);

    /// @notice Pull whatever HOLLAR has been freed for the calling vault so far
    ///         (≤ its outstanding request). Returns the amount actually sent.
    function pullFreed() external returns (uint256 hollarSent);

    /// @notice Freed-but-unpulled HOLLAR owed to `vault`.
    function freedOf(address vault) external view returns (uint256);

    /// @notice Total HOLLAR the source still owes `vault` from unwinds it has been
    ///         asked to perform but not yet fully returned — the in-flight amount
    ///         (requested minus pulled), which includes `freedOf`. 0 once every
    ///         requested unwind has been pulled. A vault checks this before
    ///         abandoning the source (e.g. `setYieldSource`) so in-flight funds
    ///         are never stranded.
    function pendingUnwindOf(address vault) external view returns (uint256);

    // ── pricing (what the vault's NAV is built on) ────────────────────────

    /// @notice `vault`'s equity in HOLLAR-USD terms at the source's live NAV.
    function equityOf(address vault) external view returns (uint256);

    /// @notice `vault`'s share balance in this source.
    function sharesOf(address vault) external view returns (uint256);

    function totalShares() external view returns (uint256);

    /// @notice Total equity held by the source (USD8, all vaults).
    function totalEquity() external view returns (uint256);

    // ── monitoring ────────────────────────────────────────────────────────

    /// @notice How far the source's live equity has fallen BELOW its cost basis,
    ///         in basis points; 0 when equity is at or above basis. This is the
    ///         mirror of the harvest surplus test (harvest skims equity above
    ///         basis) — it is the venue-agnostic "negative carry" signal. A pure
    ///         read with no side effects: callers monitor it and decide; the
    ///         contract never acts on it automatically.
    function negativeCarryBps() external view returns (uint256);

    // ── yield realisation ─────────────────────────────────────────────────

    /// @notice Realise accrued carry and forward it to the configured harvester
    ///         for per-vault, in-kind distribution. Permissionless: the payout
    ///         pins to the harvester, never to the caller.
    /// @return surplus The amount skimmed, in the source's own yield asset.
    function harvest() external returns (uint256 surplus);
}

/// @title ILeveragedLoop
/// @notice A yield source that levers a borrowed position and therefore has a
///         health factor and needs de-levering.
///
/// @dev    Deliberately split out of `IYieldSource`: an unlevered source (a plain
///         ERC-4626 wrapper, an RWA vault) has no health factor and must not be
///         forced to fake one. The keeper cranks below are the only
///         leverage-specific surface the outside world touches; `CollateralVault`
///         binds to `IYieldSource`, so it *cannot* call these — the decoupling is
///         compiler-enforced, not conventional.
interface ILeveragedLoop is IYieldSource {
    /// @notice Deploy step: borrow and lever one bounded tranche in.
    ///         Permissionless — bounded by an HF floor, a tranche cap and an
    ///         oracle-fair min-out, so a caller can only advance state.
    function pokeBorrow() external;

    /// @notice Unwind step: repay debt with freed proceeds (raising HF) and
    ///         credit freed equity to unwinding vaults pro-rata. Permissionless.
    function pokeRepay() external;

    /// @notice Safety de-lever toward the target HF — the same spiral as an
    ///         unwind, but the freed HOLLAR repays debt with no payout.
    function deLever() external;

    function healthFactor() external view returns (uint256);
}
