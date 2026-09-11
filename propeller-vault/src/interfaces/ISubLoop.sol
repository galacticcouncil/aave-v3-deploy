// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ILeveragedLoop} from "./IYieldSource.sol";

/// @title ISubLoop
/// @notice The shared PRIME/HOLLAR leveraged loop (Aave isolation mode, HF target
///         ~1.05) — **one implementation** of `IYieldSource`, not the vault's only
///         option. Funded by every CollateralVault's borrowed HOLLAR; tracks each
///         vault's equity as internal shares.
///
/// @dev    Every method lives on `IYieldSource` / `ILeveragedLoop`; this interface
///         adds nothing. It exists so call sites can name the concrete strategy
///         where that reads better, while `CollateralVault` binds only to the
///         generic seam. To plug in a different yield source (an ERC-4626/7540
///         wrapper such as BIL, which is not an Aave reserve and has no health
///         factor), implement `IYieldSource` directly — the vault needs no change.
///
///         Deploy and unwind are gradual and async, driven by keeper pokes: each
///         poke does an Aave debt leg (borrow on deploy, repay on unwind) plus a
///         synchronous HF-capped router sell (HOLLAR↔aPRIME). No flash loans. A
///         vault requests an unwind, the deleveraging spiral frees equity HOLLAR
///         over blocks, and the vault pulls it as it accrues.
interface ISubLoop is ILeveragedLoop {}
