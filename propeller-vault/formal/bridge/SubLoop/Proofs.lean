/-
  Correctness proofs for Propeller SubLoop.

  Headline: **equity-neutrality** of the keeper steps. `pokeBorrow amount` raises both
  `primeAmt` (slot 0) and `subDebt` (slot 1) by exactly `amount`; `pokeRepay amount` lowers
  both by exactly `amount`. Equal deltas ⇒ loop equity (`primeAmt − subDebt`) is invariant —
  the keeper only changes leverage, never equity. (This is why the loop's risk is rate-spread,
  not price-gap.) Plus read-only view correctness.
-/

import Contracts.SubLoop.Contract
import Contracts.SubLoop.Spec
import Verity.Proofs.Stdlib.Math
import Verity.Proofs.Stdlib.Automation

namespace Contracts.SubLoop.Proofs

open Verity
open Contracts.SubLoop.Spec
open Contracts.SubLoop
open Verity.Stdlib.Math (MAX_UINT256 requireSomeUint)
open Verity.Proofs.Stdlib.Math (safeAdd_some)
open Verity.Proofs.Stdlib.Automation (uint256_ge_val_le)

/-- Unfold `pokeBorrow` on the no-overflow path. -/
private theorem pokeBorrow_unfold (s : ContractState) (amount : Uint256)
    (h_prime : (s.storage 0 : Nat) + (amount : Nat) ≤ MAX_UINT256)
    (h_debt : (s.storage 1 : Nat) + (amount : Nat) ≤ MAX_UINT256) :
    (pokeBorrow amount).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 1 then EVM.Uint256.add (s.storage 1) amount
          else if slotIdx == 0 then EVM.Uint256.add (s.storage 0) amount
          else s.storage slotIdx,
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
  have hp := safeAdd_some (s.storage 0) amount h_prime
  have hd := safeAdd_some (s.storage 1) amount h_debt
  verity_unfold pokeBorrow
  simp only [primeAmtSlot, subDebtSlot]
  unfold requireSomeUint
  rw [hp]
  simp only [Verity.pure, Pure.pure, Bind.bind]
  rw [hd]
  simp only [Verity.pure, HAdd.hAdd]

/-- **Equity-neutral (up).** `pokeBorrow` raises `primeAmt` and `subDebt` by the *same* `amount`,
so `primeAmt − subDebt` is unchanged: leverage rises, loop equity does not. -/
theorem pokeBorrow_equity_neutral (s : ContractState) (amount : Uint256)
    (h_prime : (s.storage 0 : Nat) + (amount : Nat) ≤ MAX_UINT256)
    (h_debt : (s.storage 1 : Nat) + (amount : Nat) ≤ MAX_UINT256) :
    ((pokeBorrow amount).runState s).storage 0 = EVM.Uint256.add (s.storage 0) amount ∧
    ((pokeBorrow amount).runState s).storage 1 = EVM.Uint256.add (s.storage 1) amount := by
  have h_apply := Contract.eq_of_run_success (pokeBorrow_unfold s amount h_prime h_debt)
  simp only [Contract.runState]
  rw [h_apply]
  constructor <;> simp

/-- Unfold `pokeRepay` on the sufficient-balance path. -/
private theorem pokeRepay_unfold (s : ContractState) (amount : Uint256)
    (h_prime : s.storage 0 ≥ amount) (h_debt : s.storage 1 ≥ amount) :
    (pokeRepay amount).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 1 then EVM.Uint256.sub (s.storage 1) amount
          else if slotIdx == 0 then EVM.Uint256.sub (s.storage 0) amount
          else s.storage slotIdx,
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
  have hp := uint256_ge_val_le h_prime
  have hd := uint256_ge_val_le h_debt
  verity_unfold pokeRepay
  simp only [primeAmtSlot, subDebtSlot, h_prime, h_debt, decide_eq_true_eq, ite_true]

/-- **Equity-neutral (down).** `pokeRepay` lowers `primeAmt` and `subDebt` by the *same* `amount`,
so `primeAmt − subDebt` is unchanged: leverage falls, loop equity does not. -/
theorem pokeRepay_equity_neutral (s : ContractState) (amount : Uint256)
    (h_prime : s.storage 0 ≥ amount) (h_debt : s.storage 1 ≥ amount) :
    ((pokeRepay amount).runState s).storage 0 = EVM.Uint256.sub (s.storage 0) amount ∧
    ((pokeRepay amount).runState s).storage 1 = EVM.Uint256.sub (s.storage 1) amount := by
  have h_apply := Contract.eq_of_run_success (pokeRepay_unfold s amount h_prime h_debt)
  simp only [Contract.runState]
  rw [h_apply]
  constructor <;> simp

/-! ### Read-only views -/

theorem primeAmt_meets_spec (s : ContractState) :
    primeAmt_spec ((primeAmt).runValue s) s := by
  simp [primeAmt, primeAmt_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, primeAmtSlot]

theorem subDebt_meets_spec (s : ContractState) :
    subDebt_spec ((subDebt).runValue s) s := by
  simp [subDebt, subDebt_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, subDebtSlot]

theorem balanceOf_meets_spec (s : ContractState) (addr : Address) :
    balanceOf_spec addr ((balanceOf addr).runValue s) s := by
  simp [balanceOf, balanceOf_spec, Contract.runValue, getMapping, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, shareBalancesSlot]

end Contracts.SubLoop.Proofs
