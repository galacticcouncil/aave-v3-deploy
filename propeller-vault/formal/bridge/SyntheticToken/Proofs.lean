/-
  Correctness proofs for Propeller SyntheticToken. Modelled on
  `Contracts/ERC20/Proofs/Basic.lean` (mint is structurally identical — same slot-0 guard).
-/

import Contracts.SyntheticToken.Contract
import Contracts.SyntheticToken.Spec
import Verity.Proofs.Stdlib.Math
import Verity.Proofs.Stdlib.Automation

namespace Contracts.SyntheticToken.Proofs

open Verity
open Contracts.SyntheticToken.Spec
open Contracts.SyntheticToken
open Verity.Stdlib.Math (MAX_UINT256 requireSomeUint)
open Verity.Proofs.Stdlib.Math (safeAdd_some)
open Verity.Proofs.Stdlib.Automation (uint256_ge_val_le)

/-- `vault` returns slot 0. -/
theorem vault_meets_spec (s : ContractState) :
    vault_spec ((vault).runValue s) s := by
  simp [vault, vault_spec, Contract.runValue, getStorageAddr, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, vaultSlot]

/-- `balanceOf` returns slot 2 for `addr`. -/
theorem balanceOf_meets_spec (s : ContractState) (addr : Address) :
    balanceOf_spec addr ((balanceOf addr).runValue s) s := by
  simp [balanceOf, balanceOf_spec, Contract.runValue, getMapping, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, balancesSlot]

/-- `totalSupply` returns slot 1. -/
theorem totalSupply_meets_spec (s : ContractState) :
    totalSupply_spec ((totalSupply).runValue s) s := by
  simp [totalSupply, totalSupply_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, totalSupplySlot]

/-- Unfold `mint` on the successful vault / no-overflow path. -/
private theorem mint_unfold (s : ContractState) (toAddr : Address) (amount : Uint256)
    (h_vault : s.sender = s.storageAddr 0)
    (h_no_bal_overflow : (s.storageMap 2 toAddr : Nat) + (amount : Nat) ≤ MAX_UINT256)
    (h_no_sup_overflow : (s.storage 1 : Nat) + (amount : Nat) ≤ MAX_UINT256) :
    (mint toAddr amount).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 1 then EVM.Uint256.add (s.storage 1) amount else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := fun slotIdx addr =>
          if (slotIdx == 2 && addr == toAddr) = true then EVM.Uint256.add (s.storageMap 2 toAddr) amount
        else s.storageMap slotIdx addr,
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
        knownAddresses := fun slotIdx =>
          if slotIdx == 2 then (s.knownAddresses slotIdx).insert toAddr else s.knownAddresses slotIdx,
        events := s.events } := by
  have h_safe_bal := safeAdd_some (s.storageMap 2 toAddr) amount h_no_bal_overflow
  have h_safe_sup := safeAdd_some (s.storage 1) amount h_no_sup_overflow
  verity_unfold mint
  simp only [vaultSlot, balancesSlot, totalSupplySlot,
    h_vault, beq_self_eq_true, ite_true]
  unfold requireSomeUint
  rw [h_safe_bal]
  simp only [Verity.pure, Pure.pure, Bind.bind]
  rw [h_safe_sup]
  simp only [Verity.pure]
  simp only [HAdd.hAdd, h_vault]

/-- `mint` satisfies `mint_spec` under vault-caller and no-overflow preconditions. -/
theorem mint_meets_spec_when_vault (s : ContractState) (toAddr : Address) (amount : Uint256)
    (h_vault : s.sender = s.storageAddr 0)
    (h_no_bal_overflow : (s.storageMap 2 toAddr : Nat) + (amount : Nat) ≤ MAX_UINT256)
    (h_no_sup_overflow : (s.storage 1 : Nat) + (amount : Nat) ≤ MAX_UINT256) :
    mint_spec toAddr amount s ((mint toAddr amount).runState s) := by
  have h_unfold := mint_unfold s toAddr amount h_vault h_no_bal_overflow h_no_sup_overflow
  have h_unfold_apply := Contract.eq_of_run_success h_unfold
  simp only [Contract.runState, mint_spec]
  rw [h_unfold_apply]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · simp
  · simp
  · refine ⟨?_, ?_⟩
    · intro addr h_ne
      simp [h_ne]
    · intro slotIdx h_ne addr
      simp [h_ne]
  · intro slotIdx h_ne
    simp [h_ne]
  · rfl
  · rfl
  · rfl
  · exact Specs.sameContext_rfl _

/-- The headline functional fact: minting the synthetic raises total supply by exactly the
amount — the on-chain basis for `synth·LT` tracking the Main debt (`principalFloored`). -/
theorem mint_increases_supply_when_vault (s : ContractState) (toAddr : Address) (amount : Uint256)
    (h_vault : s.sender = s.storageAddr 0)
    (h_no_bal_overflow : (s.storageMap 2 toAddr : Nat) + (amount : Nat) ≤ MAX_UINT256)
    (h_no_sup_overflow : (s.storage 1 : Nat) + (amount : Nat) ≤ MAX_UINT256) :
    ((mint toAddr amount).runState s).storage 1 = EVM.Uint256.add (s.storage 1) amount := by
  have h := mint_meets_spec_when_vault s toAddr amount h_vault h_no_bal_overflow h_no_sup_overflow
  exact h.2.1

/-- Unfold `burn` on the successful vault / sufficient-balance path. -/
private theorem burn_unfold (s : ContractState) (fromAddr : Address) (amount : Uint256)
    (h_vault : s.sender = s.storageAddr 0)
    (h_balance : s.storageMap 2 fromAddr ≥ amount) :
    (burn fromAddr amount).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 1 then EVM.Uint256.sub (s.storage 1) amount else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := fun slotIdx addr =>
          if (slotIdx == 2 && addr == fromAddr) = true then EVM.Uint256.sub (s.storageMap 2 fromAddr) amount
        else s.storageMap slotIdx addr,
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
        knownAddresses := fun slotIdx =>
          if slotIdx == 2 then (s.knownAddresses slotIdx).insert fromAddr else s.knownAddresses slotIdx,
        events := s.events } := by
  have h_balance' := uint256_ge_val_le h_balance
  verity_unfold burn
  simp only [vaultSlot, balancesSlot, totalSupplySlot,
    h_vault, beq_self_eq_true, ite_true, h_balance, decide_eq_true_eq]

/-- `burn` satisfies `burn_spec` under vault-caller and sufficient-balance preconditions. -/
theorem burn_meets_spec_when_vault (s : ContractState) (fromAddr : Address) (amount : Uint256)
    (h_vault : s.sender = s.storageAddr 0)
    (h_balance : s.storageMap 2 fromAddr ≥ amount) :
    burn_spec fromAddr amount s ((burn fromAddr amount).runState s) := by
  have h_unfold := burn_unfold s fromAddr amount h_vault h_balance
  have h_unfold_apply := Contract.eq_of_run_success h_unfold
  simp only [Contract.runState, burn_spec]
  rw [h_unfold_apply]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · simp
  · simp
  · refine ⟨?_, ?_⟩
    · intro addr h_ne
      simp [h_ne]
    · intro slotIdx h_ne addr
      simp [h_ne]
  · intro slotIdx h_ne
    simp [h_ne]
  · rfl
  · rfl
  · rfl
  · exact Specs.sameContext_rfl _

/-- The headline functional fact for unwinding: burning the synthetic lowers total supply by
exactly the amount — the on-chain basis for the synthetic tracking the (repaid) Main debt. -/
theorem burn_decreases_supply_when_vault (s : ContractState) (fromAddr : Address) (amount : Uint256)
    (h_vault : s.sender = s.storageAddr 0)
    (h_balance : s.storageMap 2 fromAddr ≥ amount) :
    ((burn fromAddr amount).runState s).storage 1 = EVM.Uint256.sub (s.storage 1) amount := by
  have h := burn_meets_spec_when_vault s fromAddr amount h_vault h_balance
  exact h.2.1

end Contracts.SyntheticToken.Proofs
