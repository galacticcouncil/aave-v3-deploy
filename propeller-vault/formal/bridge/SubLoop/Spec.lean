/-
  Specifications for Propeller SubLoop (the PRIME-isolation leveraged loop).
-/

import Verity.Specs.Common
import Verity.Macro
import Verity.EVM.Uint256
import Contracts.SubLoop.Contract

namespace Contracts.SubLoop.Spec

open Verity
open Verity.EVM.Uint256

/-- primeAmt returns slot 0. -/
def primeAmt_spec (result : Uint256) (s : ContractState) : Prop := result = s.storage 0
/-- subDebt returns slot 1. -/
def subDebt_spec (result : Uint256) (s : ContractState) : Prop := result = s.storage 1
/-- totalShares returns slot 2. -/
def totalShares_spec (result : Uint256) (s : ContractState) : Prop := result = s.storage 2
/-- balanceOf returns slot-3 equity shares for `addr`. -/
def balanceOf_spec (addr : Address) (result : Uint256) (s : ContractState) : Prop :=
  result = s.storageMap 3 addr

end Contracts.SubLoop.Spec
