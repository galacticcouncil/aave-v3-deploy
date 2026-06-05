/-
  Correctness proofs for Propeller CollateralVault.

  Headline: the 1:1 share-conservation invariant `assets_supply_synced`
  (`storage 0 = storage 1`) is preserved by every state-changing op — deposit,
  requestRedeem, and claim. Plus read-only view correctness.
-/

import Contracts.CollateralVault.Contract
import Contracts.CollateralVault.Spec
import Verity.Proofs.Stdlib.Math
import Verity.Proofs.Stdlib.Automation

namespace Contracts.CollateralVault.Proofs

open Verity
open Contracts.CollateralVault.Spec
open Contracts.CollateralVault
open Verity.Stdlib.Math (MAX_UINT256 requireSomeUint)
open Verity.Proofs.Stdlib.Math (safeAdd_some)
open Verity.Proofs.Stdlib.Automation (uint256_ge_val_le)

/-- Unfold `deposit` on the successful (no-overflow) path. -/
private theorem deposit_unfold (s : ContractState) (assets : Uint256)
    (h_bal : (s.storageMap 2 s.sender : Nat) + (assets : Nat) ≤ MAX_UINT256)
    (h_assets : (s.storage 0 : Nat) + (assets : Nat) ≤ MAX_UINT256)
    (h_supply : (s.storage 1 : Nat) + (assets : Nat) ≤ MAX_UINT256) :
    (deposit assets).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 1 then EVM.Uint256.add (s.storage 1) assets
          else if slotIdx == 0 then EVM.Uint256.add (s.storage 0) assets
          else s.storage slotIdx,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := fun slotIdx addr =>
          if (slotIdx == 2 && addr == s.sender) = true then EVM.Uint256.add (s.storageMap 2 s.sender) assets
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
          if slotIdx == 2 then (s.knownAddresses slotIdx).insert s.sender else s.knownAddresses slotIdx,
        events := s.events } := by
  have hb := safeAdd_some (s.storageMap 2 s.sender) assets h_bal
  have ha := safeAdd_some (s.storage 0) assets h_assets
  have hs := safeAdd_some (s.storage 1) assets h_supply
  verity_unfold deposit
  simp only [shareBalancesSlot, totalAssetsSlot, totalSupplySlot]
  unfold requireSomeUint
  rw [hb]
  simp only [Verity.pure, Pure.pure, Bind.bind]
  rw [ha]
  simp only [Verity.pure, Pure.pure, Bind.bind]
  rw [hs]
  simp only [Verity.pure, HAdd.hAdd]

/-- `deposit` preserves the 1:1 invariant (`totalAssets` and `totalSupply` both rise by `assets`). -/
theorem deposit_preserves_synced (s : ContractState) (assets : Uint256)
    (h_bal : (s.storageMap 2 s.sender : Nat) + (assets : Nat) ≤ MAX_UINT256)
    (h_assets : (s.storage 0 : Nat) + (assets : Nat) ≤ MAX_UINT256)
    (h_supply : (s.storage 1 : Nat) + (assets : Nat) ≤ MAX_UINT256)
    (hsync : assets_supply_synced s) :
    assets_supply_synced ((deposit assets).runState s) := by
  have h_unfold := deposit_unfold s assets h_bal h_assets h_supply
  have h_apply := Contract.eq_of_run_success h_unfold
  simp only [Contract.runState, assets_supply_synced] at hsync ⊢
  rw [h_apply]
  simp [hsync]

/-- Unfold `requestRedeem` on the successful path (sufficient shares, no escrow overflow). -/
private theorem requestRedeem_unfold (s : ContractState) (shares : Uint256)
    (h_shares : s.storageMap 2 s.sender ≥ shares)
    (h_esc : (s.storageMap 3 s.sender : Nat) + (shares : Nat) ≤ MAX_UINT256) :
    (requestRedeem shares).run s = ContractResult.success ()
      { «storage» := s.storage,
        transientStorage := s.transientStorage,
        storageAddr := s.storageAddr,
        storageMap := fun slotIdx addr =>
          if (slotIdx == 3 && addr == s.sender) = true then EVM.Uint256.add (s.storageMap 3 s.sender) shares
          else if (slotIdx == 2 && addr == s.sender) = true then EVM.Uint256.sub (s.storageMap 2 s.sender) shares
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
          if (slotIdx == 3) = true then
            (if (slotIdx == 2) = true then (s.knownAddresses slotIdx).insert s.sender
             else s.knownAddresses slotIdx).insert s.sender
          else if (slotIdx == 2) = true then (s.knownAddresses slotIdx).insert s.sender
          else s.knownAddresses slotIdx,
        events := s.events } := by
  have h_esc' := safeAdd_some (s.storageMap 3 s.sender) shares h_esc
  have hsh := uint256_ge_val_le h_shares
  verity_unfold requestRedeem
  simp only [shareBalancesSlot, escrowSharesSlot, requireSomeUint, h_shares, h_esc',
    decide_eq_true_eq, Verity.pure, Pure.pure, Bind.bind, ite_true, HAdd.hAdd]

/-- `requestRedeem` leaves the asset/supply slots untouched, so the invariant holds. -/
theorem requestRedeem_preserves_synced (s : ContractState) (shares : Uint256)
    (h_shares : s.storageMap 2 s.sender ≥ shares)
    (h_esc : (s.storageMap 3 s.sender : Nat) + (shares : Nat) ≤ MAX_UINT256)
    (hsync : assets_supply_synced s) :
    assets_supply_synced ((requestRedeem shares).runState s) := by
  have h_unfold := requestRedeem_unfold s shares h_shares h_esc
  have h_apply := Contract.eq_of_run_success h_unfold
  simp only [Contract.runState, assets_supply_synced] at hsync ⊢
  rw [h_apply]
  exact hsync

/-- Unfold `claim` on the successful path (sufficient escrow, assets, supply). -/
private theorem claim_unfold (s : ContractState) (shares : Uint256)
    (h_esc : s.storageMap 3 s.sender ≥ shares)
    (h_assets : s.storage 0 ≥ shares)
    (h_supply : s.storage 1 ≥ shares) :
    (claim shares).run s = ContractResult.success ()
      { «storage» := fun slotIdx =>
          if slotIdx == 1 then EVM.Uint256.sub (s.storage 1) shares
          else if slotIdx == 0 then EVM.Uint256.sub (s.storage 0) shares
          else s.storage slotIdx,
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
          if slotIdx == 3 then (s.knownAddresses slotIdx).insert s.sender else s.knownAddresses slotIdx,
        events := s.events } := by
  have he := uint256_ge_val_le h_esc
  have ha := uint256_ge_val_le h_assets
  have hsu := uint256_ge_val_le h_supply
  verity_unfold claim
  simp only [escrowSharesSlot, totalAssetsSlot, totalSupplySlot,
    h_esc, h_assets, h_supply, decide_eq_true_eq, ite_true]

/-- `claim` preserves the 1:1 invariant (`totalAssets` and `totalSupply` both fall by `shares`). -/
theorem claim_preserves_synced (s : ContractState) (shares : Uint256)
    (h_esc : s.storageMap 3 s.sender ≥ shares)
    (h_assets : s.storage 0 ≥ shares)
    (h_supply : s.storage 1 ≥ shares)
    (hsync : assets_supply_synced s) :
    assets_supply_synced ((claim shares).runState s) := by
  have h_unfold := claim_unfold s shares h_esc h_assets h_supply
  have h_apply := Contract.eq_of_run_success h_unfold
  simp only [Contract.runState, assets_supply_synced] at hsync ⊢
  rw [h_apply]
  simp [hsync]

/-! ### Read-only views -/

theorem balanceOf_meets_spec (s : ContractState) (addr : Address) :
    balanceOf_spec addr ((balanceOf addr).runValue s) s := by
  simp [balanceOf, balanceOf_spec, Contract.runValue, getMapping, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, shareBalancesSlot]

theorem escrowOf_meets_spec (s : ContractState) (addr : Address) :
    escrowOf_spec addr ((escrowOf addr).runValue s) s := by
  simp [escrowOf, escrowOf_spec, Contract.runValue, getMapping, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, escrowSharesSlot]

theorem totalAssets_meets_spec (s : ContractState) :
    totalAssets_spec ((totalAssets).runValue s) s := by
  simp [totalAssets, totalAssets_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, totalAssetsSlot]

theorem totalSupply_meets_spec (s : ContractState) :
    totalSupply_spec ((totalSupply).runValue s) s := by
  simp [totalSupply, totalSupply_spec, Contract.runValue, getStorage, Verity.bind, Bind.bind,
    Verity.pure, Pure.pure, totalSupplySlot]

end Contracts.CollateralVault.Proofs
