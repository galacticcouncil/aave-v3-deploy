/- Specifications for Propeller Harvester (keeper guards). -/

import Verity.Specs.Common
import Verity.Macro
import Verity.EVM.Uint256
import Contracts.Harvester.Contract

namespace Contracts.Harvester.Spec

open Verity
open Verity.EVM.Uint256

def subHealth_spec (result : Uint256) (s : ContractState) : Prop := result = s.storage 0
def synthValue_spec (result : Uint256) (s : ContractState) : Prop := result = s.storage 2
def mainDebt_spec (result : Uint256) (s : ContractState) : Prop := result = s.storage 3

end Contracts.Harvester.Spec
