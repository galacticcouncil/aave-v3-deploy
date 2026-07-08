import Contracts.Common

/-!
  Propeller `Harvester` — the keeper (see `propeller-vault/src/Harvester.sol` and the ℝ-spec
  in `propeller-vault/formal/`). Permissionless entrypoints, each **re-checking on-chain guards**
  (HF / carry / peg), mirroring HSM `execute_arbitrage` / liquidation `liquidate`.

  This cut models the guard logic — the verifiable safety core:
  * `maintainPeg` re-establishes the synthetic floor (`synthValue ≥ mainDebt`) after interest accrual.
  * `deLever` is **guarded**: it reverts unless the loop is at/under the de-lever trigger, so a healthy
    loop can never be force-de-levered; when it does fire, it restores health to the trigger.

  The actual Aave repay / synthetic mint are ECMs (next). Health/debt/synth values are scaled
  integers fed from the loop & main position (cross-contract reads = ECMs).
-/

namespace Contracts

open Verity hiding pure bind
open Verity.EVM.Uint256
open Verity.Stdlib.Math

verity_contract Harvester where
  storage
    subHealthSlot      : Uint256 := slot 0   -- sub-loop HF, scaled (e.g. ×100: 1.05 → 105)
    deLeverTriggerSlot : Uint256 := slot 1   -- de-lever threshold (e.g. 110 = HF 1.10)
    synthValueSlot     : Uint256 := slot 2   -- synthetic risk-weighted value
    mainDebtSlot       : Uint256 := slot 3   -- Main HOLLAR debt

  interfaces
    interface ISubLoop where
      function pokeRepay(Uint256) returns (Bool)
    end

  constructor (trigger : Uint256) := do
    setStorage deLeverTriggerSlot trigger
    setStorage subHealthSlot 0
    setStorage synthValueSlot 0
    setStorage mainDebtSlot 0

  -- re-establish the floor: set synthValue := mainDebt (mirrors ℝ `maintainPeg_floors`).
  function maintainPeg () : Unit := do
    let debt ← getStorage mainDebtSlot
    setStorage synthValueSlot debt

  -- guarded keeper step: only when the loop is at/under the trigger (HF ≤ 1.10).
  function deLever () : Unit := do
    let h ← getStorage subHealthSlot
    let trig ← getStorage deLeverTriggerSlot
    require (h <= trig) "HARV: loop healthy, no de-lever"
    -- (ECM: SubLoop.pokeRepay raises HF) — model: health restored up to the trigger.
    setStorage subHealthSlot trig

  -- guarded de-lever that actually drives the loop: same guard as `deLever`, then the
  -- inter-contract call `SubLoop.pokeRepay` (Harvester → SubLoop). Check → effect → interaction,
  -- so no `allow_post_interaction_writes` needed (the lone external call follows the state write).
  function deLeverLoop (loop : ISubLoop, amount : Uint256) : Unit := do
    let h ← getStorage subHealthSlot
    let trig ← getStorage deLeverTriggerSlot
    require (h <= trig) "HARV: loop healthy, no de-lever"
    setStorage subHealthSlot trig
    let _repaid ← loop.pokeRepay amount

  function subHealth () : Uint256 := do
    let h ← getStorage subHealthSlot
    return h

  function synthValue () : Uint256 := do
    let v ← getStorage synthValueSlot
    return v

  function mainDebt () : Uint256 := do
    let d ← getStorage mainDebtSlot
    return d

  function deLeverTrigger () : Uint256 := do
    let t ← getStorage deLeverTriggerSlot
    return t

end Contracts
