// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ISubLoop
/// @notice The single shared PRIME/HOLLAR leveraged loop (Aave isolation mode,
///         HF target ~1.05). Funded by every CollateralVault's borrowed HOLLAR;
///         tracks each vault's equity as internal shares.
///
/// @dev    Deploy and unwind are **gradual and async**, driven by an unbounded
///         DCA order (HOLLAR↔aPRIME, via IDcaScheduler) plus keeper pokes that
///         do only the Aave debt legs (borrow on deploy, repay on unwind). No
///         flash loans. Withdrawals are async: a vault requests an unwind, the
///         deleveraging spiral frees equity HOLLAR over blocks, the vault pulls
///         it as it accrues and settles its own redemption queue.
interface ISubLoop {
    // ── deposit (deploy) ──────────────────────────────────────────────────
    /// @notice Add `hollarAmount` (pulled from the caller-vault) to the deploy
    ///         budget and credit equity shares. The unbounded deploy DCA + the
    ///         keeper `pokeBorrow` ramp it into the loop over blocks.
    function deposit(uint256 hollarAmount) external returns (uint256 shares);

    // ── withdraw (unwind) ─────────────────────────────────────────────────
    /// @notice Begin unwinding `shares` of the caller-vault's equity. Burns the
    ///         vault's loop shares and grows the unwind target; the spiral frees
    ///         the equity HOLLAR over blocks. Returns an id for tracking.
    function requestUnwind(uint256 shares) external returns (uint256 unwindId);

    /// @notice Vault pulls equity HOLLAR that the unwind spiral has freed for it
    ///         so far (≤ its outstanding unwind request). Returns amount sent.
    function pullFreed() external returns (uint256 hollarSent);

    /// @notice Freed-but-unpulled equity HOLLAR for a vault.
    function freedOf(address vault) external view returns (uint256);

    // ── keeper ────────────────────────────────────────────────────────────
    /// @notice Deploy step: borrow HOLLAR up to a safe margin above target HF
    ///         and lever the tranche in (synchronous router sell, no DCA).
    ///         permissionless — bounded by deployHfFloor + deployTranche + minOut.
    function pokeBorrow() external;

    /// @notice Unwind step: repay loop debt with HOLLAR the unwind DCA produced
    ///         (delevering, raising HF) and credit freed equity to unwinding
    ///         vaults pro-rata.
    function pokeRepay() external;

    /// @notice Realize accrued carry: skim the surplus PRIME and send it to the
    ///         configured harvester for per-vault, in-kind distribution.
    ///         Permissionless — the payout pins to the harvester, not the caller.
    function harvest() external returns (uint256 surplusPrime);

    /// @notice Safety de-lever toward target HF (same spiral as unwind, but the
    ///         freed HOLLAR repays loop debt with no payout). Guarded on HF.
    function deLever() external;

    // ── views ─────────────────────────────────────────────────────────────
    function healthFactor() external view returns (uint256);
    function totalEquity() external view returns (uint256);
    function equityOf(address vault) external view returns (uint256);
    function sharesOf(address vault) external view returns (uint256);
    function totalShares() external view returns (uint256);
}
