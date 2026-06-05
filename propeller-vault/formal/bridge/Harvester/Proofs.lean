/-
  Correctness proofs for Propeller Harvester (the keeper).

  Headlines:
  * `maintainPeg_restores_floor` — after `maintainPeg`, `synthValue ≥ mainDebt`: the on-chain
    re-establishment of `principalFloored` (mirrors ℝ `maintainPeg_floors`).
  * `deLever_reverts_when_healthy` — `deLever` **reverts** when the loop is above the trigger
    (`subHealth > trigger`): a healthy loop can never be force-de-levered (guard enforcement).
  * `deLever_succeeds_when_unhealthy` — when `subHealth ≤ trigger`, `deLever` proceeds and restores
    health to the trigger.
-/

import Contracts.Harvester.Contract
import Contracts.Harvester.Spec
import Verity.Proofs.Stdlib.Automation

namespace Contracts.Harvester.Proofs

open Verity
open Contracts.Harvester.Spec
open Contracts.Harvester

/-- Unfold `maintainPeg`: sets `synthValue` (slot 2) to `mainDebt` (slot 3). -/
private theorem maintainPeg_unfold (s : ContractState) :
    (maintainPeg).run s = ContractResult.success ()
      { «storage» := fun slotIdx => if slotIdx == 2 then s.storage 3 else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := s.storageMap,
        storageMapUint := s.storageMapUint,
        storageMap2 := s.storageMap2,
        storageArray := s.storageArray,
        sender := s.sender,
        thisAddress := s.thisAddress,
        msgValue := s.msgValue,
        selfBalance := s.selfBalance,
        blockTimestamp := s.blockTimestamp,
        blockNumber := s.blockNumber,
        chainId := s.chainId,
        blobBaseFee := s.blobBaseFee,
        calldataSize := s.calldataSize,
        calldata := s.calldata,
        memory := s.memory,
        knownAddresses := s.knownAddresses,
        events := s.events } := by
  verity_unfold maintainPeg
  simp only [mainDebtSlot, synthValueSlot]

/-- **Floor restoration.** After `maintainPeg`, the synthetic value covers the Main debt:
`synthValue ≥ mainDebt` — the on-chain `principalFloored`, re-established regardless of how far
interest accrual had eroded it. -/
theorem maintainPeg_restores_floor (s : ContractState) :
    ((maintainPeg).runState s).storage 2 ≥ ((maintainPeg).runState s).storage 3 := by
  have h_apply := Contract.eq_of_run_success (maintainPeg_unfold s)
  simp only [Contract.runState]
  rw [h_apply]
  simp

/-- Unfold `deLever` on the success path (loop at/under trigger): sets `subHealth := trigger`. -/
private theorem deLever_unfold (s : ContractState) (h : s.storage 0 ≤ s.storage 1) :
    (deLever).run s = ContractResult.success ()
      { «storage» := fun slotIdx => if slotIdx == 0 then s.storage 1 else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := s.storageMap,
        storageMapUint := s.storageMapUint,
        storageMap2 := s.storageMap2,
        storageArray := s.storageArray,
        sender := s.sender,
        thisAddress := s.thisAddress,
        msgValue := s.msgValue,
        selfBalance := s.selfBalance,
        blockTimestamp := s.blockTimestamp,
        blockNumber := s.blockNumber,
        chainId := s.chainId,
        blobBaseFee := s.blobBaseFee,
        calldataSize := s.calldataSize,
        calldata := s.calldata,
        memory := s.memory,
        knownAddresses := s.knownAddresses,
        events := s.events } := by
  verity_unfold deLever
  simp only [subHealthSlot, deLeverTriggerSlot, h, decide_eq_true_eq, ite_true]

/-- **Guard fires the action.** When the loop is at/under the trigger, `deLever` restores
`subHealth` to the trigger level. -/
theorem deLever_succeeds_when_unhealthy (s : ContractState) (h : s.storage 0 ≤ s.storage 1) :
    ((deLever).runState s).storage 0 = s.storage 1 := by
  have h_apply := Contract.eq_of_run_success (deLever_unfold s h)
  simp only [Contract.runState]
  rw [h_apply]
  simp

/-- **Guard enforcement.** When the loop is healthy — the guard condition fails, i.e.
`¬ (subHealth ≤ trigger)` (`subHealth` strictly above the de-lever trigger) — `deLever` reverts.
A healthy loop can never be force-de-levered. -/
theorem deLever_reverts_when_healthy (s : ContractState)
    (hnle : ¬ (s.storage 0 ≤ s.storage 1)) :
    (deLever).run s = ContractResult.revert "HARV: loop healthy, no de-lever" s := by
  have hval : ¬ ((s.storage 0).val ≤ (s.storage 1).val) := by
    rwa [Verity.Core.Uint256.le_def] at hnle
  verity_unfold deLever
  simp [subHealthSlot, deLeverTriggerSlot, hval]

/-- **Guard enforcement survives the inter-contract wiring.** `deLeverLoop` (which calls
`SubLoop.pokeRepay`) still reverts when the loop is healthy — the guard precedes the state write
and the external call, so a healthy loop can never be de-levered. -/
theorem deLeverLoop_reverts_when_healthy (s : ContractState) (loop : Verity.Address) (amount : Uint256)
    (hnle : ¬ (s.storage 0 ≤ s.storage 1)) :
    (deLeverLoop loop amount).run s = ContractResult.revert "HARV: loop healthy, no de-lever" s := by
  have hval : ¬ ((s.storage 0).val ≤ (s.storage 1).val) := by
    rwa [Verity.Core.Uint256.le_def] at hnle
  verity_unfold deLeverLoop
  simp [subHealthSlot, deLeverTriggerSlot, hval]

/-! ### Read-only views -/

theorem subHealth_meets_spec (s : ContractState) :
    subHealth_spec ((subHealth).runValue s) s := by
  simp [subHealth, subHealth_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, subHealthSlot]

theorem synthValue_meets_spec (s : ContractState) :
    synthValue_spec ((synthValue).runValue s) s := by
  simp [synthValue, synthValue_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, synthValueSlot]

end Contracts.Harvester.Proofs
