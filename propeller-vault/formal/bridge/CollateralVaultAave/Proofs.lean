/-
  deploy-side access-control proof for the Aave-wired vault.
-/

import Contracts.CollateralVaultAave.Contract
import Verity.Proofs.Stdlib.Automation

namespace Contracts.CollateralVaultAave.Proofs

open Verity
open Contracts.CollateralVaultAave
open Verity.Proofs.Stdlib.Automation (address_beq_false_of_ne)

/-- **keeper access control.** `pokeSettle` reverts unless the caller is the registered keeper
(slot 5) — no non-keeper can drive the unwind/settle (and so cannot touch the aave repay/withdraw).
The guard precedes every effect and external call, so the revert leaves state untouched. -/
theorem pokeSettle_reverts_when_not_keeper (s : ContractState)
    (pool hollar asset onBehalfOf recipient : Address) (repayAmount withdrawAmount : Uint256)
    (h : s.sender ≠ s.storageAddr 5) :
    (pokeSettle pool hollar asset onBehalfOf recipient repayAmount withdrawAmount).run s
      = ContractResult.revert "VAULT: only keeper" s := by
  verity_unfold pokeSettle
  simp [keeperSlot, address_beq_false_of_ne s.sender (s.storageAddr 5) h]

end Contracts.CollateralVaultAave.Proofs
