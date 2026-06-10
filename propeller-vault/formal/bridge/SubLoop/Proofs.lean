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

/-- Unfold `pokeBorrow` on the authorized (controller) no-overflow path. -/
private theorem pokeBorrow_unfold (s : ContractState) (amount : Uint256)
    (h_ctrl : s.sender = s.storageAddr 4)
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
        txOrigin := s.txOrigin,
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
  simp only [primeAmtSlot, subDebtSlot, controllerSlot, h_ctrl, beq_self_eq_true, ite_true]
  unfold requireSomeUint
  rw [hp]
  simp only [Verity.pure, Pure.pure, Bind.bind]
  rw [hd]
  simp only [Verity.pure, HAdd.hAdd, h_ctrl]

/-- **Equity-neutral (up).** `pokeBorrow` raises `primeAmt` and `subDebt` by the *same* `amount`,
so `primeAmt − subDebt` is unchanged: leverage rises, loop equity does not. -/
theorem pokeBorrow_equity_neutral (s : ContractState) (amount : Uint256)
    (h_ctrl : s.sender = s.storageAddr 4)
    (h_prime : (s.storage 0 : Nat) + (amount : Nat) ≤ MAX_UINT256)
    (h_debt : (s.storage 1 : Nat) + (amount : Nat) ≤ MAX_UINT256) :
    ((pokeBorrow amount).runState s).storage 0 = EVM.Uint256.add (s.storage 0) amount ∧
    ((pokeBorrow amount).runState s).storage 1 = EVM.Uint256.add (s.storage 1) amount := by
  have h_apply := Contract.eq_of_run_success (pokeBorrow_unfold s amount h_ctrl h_prime h_debt)
  simp only [Contract.runState]
  rw [h_apply]
  constructor <;> simp

/-- Unfold `pokeRepay` on the sufficient-balance path. -/
private theorem pokeRepay_unfold (s : ContractState) (amount : Uint256)
    (h_ctrl : s.sender = s.storageAddr 4)
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
        txOrigin := s.txOrigin,
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
  simp only [primeAmtSlot, subDebtSlot, controllerSlot, h_ctrl, beq_self_eq_true,
    h_prime, h_debt, decide_eq_true_eq, ite_true]

/-- **Equity-neutral (down).** `pokeRepay` lowers `primeAmt` and `subDebt` by the *same* `amount`,
so `primeAmt − subDebt` is unchanged: leverage falls, loop equity does not. -/
theorem pokeRepay_equity_neutral (s : ContractState) (amount : Uint256)
    (h_ctrl : s.sender = s.storageAddr 4)
    (h_prime : s.storage 0 ≥ amount) (h_debt : s.storage 1 ≥ amount) :
    ((pokeRepay amount).runState s).storage 0 = EVM.Uint256.sub (s.storage 0) amount ∧
    ((pokeRepay amount).runState s).storage 1 = EVM.Uint256.sub (s.storage 1) amount := by
  have h_apply := Contract.eq_of_run_success (pokeRepay_unfold s amount h_ctrl h_prime h_debt)
  simp only [Contract.runState]
  rw [h_apply]
  constructor <;> simp

/-! ### Deploy-side access control: the pokes revert for a non-controller caller. -/

open Verity.Proofs.Stdlib.Automation (address_beq_false_of_ne) in
theorem pokeBorrow_reverts_when_not_controller (s : ContractState) (amount : Uint256)
    (h : s.sender ≠ s.storageAddr 4) :
    (pokeBorrow amount).run s = ContractResult.revert "LOOP: only controller" s := by
  verity_unfold pokeBorrow
  simp [controllerSlot, address_beq_false_of_ne s.sender (s.storageAddr 4) h]

open Verity.Proofs.Stdlib.Automation (address_beq_false_of_ne) in
theorem pokeRepay_reverts_when_not_controller (s : ContractState) (amount : Uint256)
    (h : s.sender ≠ s.storageAddr 4) :
    (pokeRepay amount).run s = ContractResult.revert "LOOP: only controller" s := by
  verity_unfold pokeRepay
  simp [controllerSlot, address_beq_false_of_ne s.sender (s.storageAddr 4) h]

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

/-! ### Multi-vault share accounting: conservation + cross-vault isolation

`deposit` and `requestUnwind` are the only ops that move the per-vault share book (slot 3) and the
stored `totalShares` (slot 2). The on-chain `SubLoop` is shared by many vaults, so the safety-critical
facts are: (1) the caller's entry and `totalShares` change by the **same** amount — conservation — and
(2) **no other vault's** entry moves — isolation (the "PRIME-isolation" claim). -/

open Verity.Proofs.Stdlib.Automation (address_beq_false_of_ne)

/-- Unfold `deposit` on the no-overflow path. -/
private theorem deposit_unfold (s : ContractState) (seed : Uint256)
    (h_sh : (s.storageMap 3 s.sender : Nat) + (seed : Nat) ≤ MAX_UINT256)
    (h_pr : (s.storage 0 : Nat) + (seed : Nat) ≤ MAX_UINT256)
    (h_su : (s.storage 2 : Nat) + (seed : Nat) ≤ MAX_UINT256) :
    (deposit seed).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 2 then EVM.Uint256.add (s.storage 2) seed
          else if slotIdx == 0 then EVM.Uint256.add (s.storage 0) seed
          else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := fun slotIdx addr =>
          if (slotIdx == 3 && addr == s.sender) = true then EVM.Uint256.add (s.storageMap 3 s.sender) seed
          else s.storageMap slotIdx addr,
        storageMapUint := s.storageMapUint,
        storageMap2 := s.storageMap2,
        storageArray := s.storageArray,
        sender := s.sender,
        thisAddress := s.thisAddress,
        txOrigin := s.txOrigin,
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
          if slotIdx == 3 then (s.knownAddresses slotIdx).insert s.sender
          else s.knownAddresses slotIdx,
        events := s.events } := by
  have h_sh' := safeAdd_some (s.storageMap 3 s.sender) seed h_sh
  have h_pr' := safeAdd_some (s.storage 0) seed h_pr
  have h_su' := safeAdd_some (s.storage 2) seed h_su
  simp only [deposit, shareBalancesSlot, primeAmtSlot, totalSharesSlot, msgSender, getMapping,
    getStorage, setMapping, setStorage, requireSomeUint, Verity.pure, Verity.bind, Bind.bind,
    Pure.pure, Contract.run, h_sh', h_pr', h_su', beq_iff_eq, decide_eq_true_eq,
    ite_true, ite_false, HAdd.hAdd]

/-- **Conservation (deposit):** the caller's share entry and `totalShares` both rise by exactly
`seed` — equal deltas, so `∑ shares = totalShares` is preserved. -/
theorem deposit_conserves (s : ContractState) (seed : Uint256)
    (h_sh : (s.storageMap 3 s.sender : Nat) + (seed : Nat) ≤ MAX_UINT256)
    (h_pr : (s.storage 0 : Nat) + (seed : Nat) ≤ MAX_UINT256)
    (h_su : (s.storage 2 : Nat) + (seed : Nat) ≤ MAX_UINT256) :
    ((deposit seed).runState s).storageMap 3 s.sender = EVM.Uint256.add (s.storageMap 3 s.sender) seed ∧
    ((deposit seed).runState s).storage 2 = EVM.Uint256.add (s.storage 2) seed := by
  have h := Contract.eq_of_run_success (deposit_unfold s seed h_sh h_pr h_su)
  simp only [Contract.runState]; rw [h]; constructor <;> simp

/-- **Isolation (deposit):** a deposit by `s.sender` leaves every other vault's share entry
untouched — no cross-vault contamination. -/
theorem deposit_isolation (s : ContractState) (seed : Uint256) (other : Address)
    (h_other : other ≠ s.sender)
    (h_sh : (s.storageMap 3 s.sender : Nat) + (seed : Nat) ≤ MAX_UINT256)
    (h_pr : (s.storage 0 : Nat) + (seed : Nat) ≤ MAX_UINT256)
    (h_su : (s.storage 2 : Nat) + (seed : Nat) ≤ MAX_UINT256) :
    ((deposit seed).runState s).storageMap 3 other = s.storageMap 3 other := by
  have h := Contract.eq_of_run_success (deposit_unfold s seed h_sh h_pr h_su)
  simp only [Contract.runState]; rw [h]
  simp [address_beq_false_of_ne other s.sender h_other]

/-- Unfold `requestUnwind` on the sufficient-balance path. -/
private theorem requestUnwind_unfold (s : ContractState) (shares : Uint256)
    (h_sh : s.storageMap 3 s.sender ≥ shares) (h_su : s.storage 2 ≥ shares) :
    (requestUnwind shares).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 2 then EVM.Uint256.sub (s.storage 2) shares else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := fun slotIdx addr =>
          if (slotIdx == 3 && addr == s.sender) = true then EVM.Uint256.sub (s.storageMap 3 s.sender) shares
          else s.storageMap slotIdx addr,
        storageMapUint := s.storageMapUint,
        storageMap2 := s.storageMap2,
        storageArray := s.storageArray,
        sender := s.sender,
        thisAddress := s.thisAddress,
        txOrigin := s.txOrigin,
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
          if slotIdx == 3 then (s.knownAddresses slotIdx).insert s.sender
          else s.knownAddresses slotIdx,
        events := s.events } := by
  have h_sh' := uint256_ge_val_le h_sh
  have h_su' := uint256_ge_val_le h_su
  simp only [requestUnwind, shareBalancesSlot, totalSharesSlot, msgSender, getMapping, getStorage,
    setMapping, setStorage, Verity.require, Verity.pure, Verity.bind, Bind.bind, Pure.pure,
    Contract.run, h_sh, h_su, beq_iff_eq, decide_eq_true_eq, ite_true, ite_false]

/-- **Conservation (requestUnwind):** the caller's entry and `totalShares` both fall by exactly
`shares` — equal deltas, conservation preserved. -/
theorem requestUnwind_conserves (s : ContractState) (shares : Uint256)
    (h_sh : s.storageMap 3 s.sender ≥ shares) (h_su : s.storage 2 ≥ shares) :
    ((requestUnwind shares).runState s).storageMap 3 s.sender = EVM.Uint256.sub (s.storageMap 3 s.sender) shares ∧
    ((requestUnwind shares).runState s).storage 2 = EVM.Uint256.sub (s.storage 2) shares := by
  have h := Contract.eq_of_run_success (requestUnwind_unfold s shares h_sh h_su)
  simp only [Contract.runState]; rw [h]; constructor <;> simp

/-- **Isolation (requestUnwind):** burning the caller's shares leaves every other vault untouched. -/
theorem requestUnwind_isolation (s : ContractState) (shares : Uint256) (other : Address)
    (h_other : other ≠ s.sender)
    (h_sh : s.storageMap 3 s.sender ≥ shares) (h_su : s.storage 2 ≥ shares) :
    ((requestUnwind shares).runState s).storageMap 3 other = s.storageMap 3 other := by
  have h := Contract.eq_of_run_success (requestUnwind_unfold s shares h_sh h_su)
  simp only [Contract.runState]; rw [h]
  simp [address_beq_false_of_ne other s.sender h_other]

/-! ### Redemption credit `_creditFreed` (2-vault unroll): no over-credit on the run-model

The deployed `SubLoop` credits freed HOLLAR pro-rata by `rem = requested − freed`. `creditFreed2` is
that step for two unwinders (Verity v0.1.0 has no in-contract loop). The safety property: `reservedFreed`
grows by at most `freed`, so it never exceeds the loop's actual HOLLAR (pulls can't revert). -/

open Verity.Stdlib.Math (mulDivDown)
open Verity.Proofs.Stdlib.Math (mulDivDown_nat_eq)
open Verity.Core.Uint256 (coe_ofNat)

/-- Arithmetic core: two floored `rem`-weighted cuts sum to `≤ freed` when `rem₁+rem₂ = target`
(this is what the `rem` weighting buys — the buggy `requested` weighting fails it). -/
theorem creditFreed2_cuts_le (freed rem1 rem2 target : Uint256)
    (hmatch : (rem1 : Nat) + (rem2 : Nat) = (target : Nat)) (hT : 0 < (target : Nat))
    (hov1 : (freed : Nat) * (rem1 : Nat) ≤ MAX_UINT256)
    (hov2 : (freed : Nat) * (rem2 : Nat) ≤ MAX_UINT256) :
    (mulDivDown freed rem1 target : Nat) + (mulDivDown freed rem2 target : Nat) ≤ (freed : Nat) := by
  rw [mulDivDown_nat_eq freed rem1 target hov1, mulDivDown_nat_eq freed rem2 target hov2,
    if_neg hT.ne', if_neg hT.ne']
  have key : (freed : Nat) * (rem1 : Nat) / (target : Nat) + (freed : Nat) * (rem2 : Nat) / (target : Nat)
           ≤ ((freed : Nat) * (rem1 : Nat) + (freed : Nat) * (rem2 : Nat)) / (target : Nat) := by
    rw [Nat.le_div_iff_mul_le hT, add_mul]
    exact Nat.add_le_add (Nat.div_mul_le_self _ _) (Nat.div_mul_le_self _ _)
  refine key.trans (le_of_eq ?_)
  rw [← Nat.mul_add, hmatch, Nat.mul_div_cancel _ hT]

/-- `add` (which wraps mod 2²⁵⁶) never exceeds the true Nat sum. -/
private theorem add_coe_le (a b : Uint256) : ((a + b : Uint256) : Nat) ≤ (a : Nat) + (b : Nat) := by
  show ((Verity.Core.Uint256.add a b : Uint256) : Nat) ≤ _
  simp only [Verity.Core.Uint256.add, coe_ofNat]
  exact Nat.mod_le _ _

/-- The total credited (`cut₁+cut₂`, with `add`'s wrapping) is `≤ freed`. -/
theorem creditFreed2_credited_le (freed rem1 rem2 target : Uint256)
    (hmatch : (rem1 : Nat) + (rem2 : Nat) = (target : Nat)) (hT : 0 < (target : Nat))
    (hov1 : (freed : Nat) * (rem1 : Nat) ≤ MAX_UINT256)
    (hov2 : (freed : Nat) * (rem2 : Nat) ≤ MAX_UINT256) :
    ((mulDivDown freed rem1 target + mulDivDown freed rem2 target : Uint256) : Nat) ≤ (freed : Nat) :=
  (add_coe_le _ _).trans (creditFreed2_cuts_le freed rem1 rem2 target hmatch hT hov1 hov2)

/-- Run-model: after `creditFreed2`, `reservedFreed` (slot 8) is the old value plus the two cuts. -/
theorem creditFreed2_reserved (s : ContractState) (v1 v2 : Address) (freed : Uint256) :
    ((creditFreed2 v1 v2 freed).runState s).storage 8
      = s.storage 8
        + (mulDivDown freed (EVM.Uint256.sub (s.storageMap 5 v1) (s.storageMap 6 v1)) (s.storage 7)
           + mulDivDown freed (EVM.Uint256.sub (s.storageMap 5 v2) (s.storageMap 6 v2)) (s.storage 7)) := by
  simp only [creditFreed2, Contract.runState, unwindTargetSlot, unwindRequestedSlot,
    freedHollarSlot, reservedFreedSlot, getStorage, getMapping, setStorage, setMapping,
    Verity.bind, Bind.bind, Verity.pure, Pure.pure]
  rfl

/-- **No over-credit on the contract run:** `reservedFreed` grows by at most `freed`, so it never
overstates the loop's freed HOLLAR — pulls can never revert on balance. Holds when the two
remaining-to-credit slices sum to the outstanding `unwindTarget` (the `Σ rem = target` invariant). -/
theorem creditFreed2_no_over_credit (s : ContractState) (v1 v2 : Address) (freed : Uint256)
    (hmatch : (EVM.Uint256.sub (s.storageMap 5 v1) (s.storageMap 6 v1) : Nat)
              + (EVM.Uint256.sub (s.storageMap 5 v2) (s.storageMap 6 v2) : Nat) = (s.storage 7 : Nat))
    (hT : 0 < (s.storage 7 : Nat))
    (hov1 : (freed : Nat) * (EVM.Uint256.sub (s.storageMap 5 v1) (s.storageMap 6 v1) : Nat) ≤ MAX_UINT256)
    (hov2 : (freed : Nat) * (EVM.Uint256.sub (s.storageMap 5 v2) (s.storageMap 6 v2) : Nat) ≤ MAX_UINT256) :
    (((creditFreed2 v1 v2 freed).runState s).storage 8 : Nat) ≤ (s.storage 8 : Nat) + (freed : Nat) := by
  rw [creditFreed2_reserved s v1 v2 freed]
  exact (add_coe_le _ _).trans
    (Nat.add_le_add_left (creditFreed2_credited_le freed _ _ _ hmatch hT hov1 hov2) _)

end Contracts.SubLoop.Proofs
