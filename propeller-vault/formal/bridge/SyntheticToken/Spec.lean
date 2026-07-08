/-
  Formal specifications for Propeller SyntheticToken operations.
  Modelled on `Contracts/ERC20/Spec.lean`.
-/

import Verity.Specs.Common
import Verity.Macro
import Verity.EVM.Uint256

namespace Contracts.SyntheticToken.Spec

open Verity
open Verity.EVM.Uint256
open Verity.Specs

/-! ## Operation specifications -/

-- constructor: stores the vault address at slot 0 and zeroes total supply at slot 1.
#gen_spec_addr_storage constructor_spec for (vault : Address)
  (0, 1, (fun _ => vault), (fun _ => 0), sameStorageMap2Context)

-- mint: increases recipient balance (slot 2) and total supply (slot 1) by `amount`.
#gen_spec_map_storage mint_spec for (toAddr : Address) (amount : Uint256)
  (2, toAddr, (fun st => add (st.storageMap 2 toAddr) amount), 1,
   (fun st => add (st.storage 1) amount), sameStorageAddrSlotMap2Context 0)

-- burn: decreases holder balance (slot 2) and total supply (slot 1) by `amount`.
#gen_spec_map_storage burn_spec for (fromAddr : Address) (amount : Uint256)
  (2, fromAddr, (fun st => sub (st.storageMap 2 fromAddr) amount), 1,
   (fun st => sub (st.storage 1) amount), sameStorageAddrSlotMap2Context 0)

/-- balanceOf: returns the balance at slot 2 for `addr`. -/
def balanceOf_spec (addr : Address) (result : Uint256) (s : ContractState) : Prop :=
  result = s.storageMap 2 addr

/-- totalSupply: returns slot 1. -/
def totalSupply_spec (result : Uint256) (s : ContractState) : Prop :=
  result = s.storage 1

/-- vault: returns the vault address at slot 0. -/
def vault_spec (result : Address) (s : ContractState) : Prop :=
  result = s.storageAddr 0

end Contracts.SyntheticToken.Spec
