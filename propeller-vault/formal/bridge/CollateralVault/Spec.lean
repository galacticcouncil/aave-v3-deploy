/-
  Specifications & the share-conservation invariant for Propeller CollateralVault.
-/

import Verity.Specs.Common
import Verity.Macro
import Verity.EVM.Uint256
import Contracts.CollateralVault.Contract

namespace Contracts.CollateralVault.Spec

open Verity
open Verity.EVM.Uint256
open Verity.Specs

/-- **Invariant of record (shareConservation):** collateral backing equals shares
outstanding, 1:1. Slot 0 (`totalAssets`) = slot 1 (`totalSupply`). -/
def assets_supply_synced (s : ContractState) : Prop :=
  s.storage 0 = s.storage 1

/-- balanceOf returns slot-2 shares for `addr`. -/
def balanceOf_spec (addr : Address) (result : Uint256) (s : ContractState) : Prop :=
  result = s.storageMap 2 addr

/-- escrowOf returns slot-3 escrowed shares for `addr`. -/
def escrowOf_spec (addr : Address) (result : Uint256) (s : ContractState) : Prop :=
  result = s.storageMap 3 addr

/-- totalAssets returns slot 0. -/
def totalAssets_spec (result : Uint256) (s : ContractState) : Prop :=
  result = s.storage 0

/-- totalSupply returns slot 1. -/
def totalSupply_spec (result : Uint256) (s : ContractState) : Prop :=
  result = s.storage 1

end Contracts.CollateralVault.Spec
