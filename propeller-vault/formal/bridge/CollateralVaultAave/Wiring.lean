/-
  Machine-checked wiring facts for the Aave-wired CollateralVault.

  These `decide` proofs verify, against the compilation model the Verity compiler consumes, that
  `deposit` actually issues the Aave `IPool.supply` cross-contract call (as an `externalCallWithReturn`
  ECM). This is the same verification standard Verity uses for its own typed-interface contracts
  (`Contracts/Smoke/InternalInterfaceSmoke.lean`). `decide` ⇒ no extra axioms.
-/

import Contracts.CollateralVaultAave.Contract

namespace Contracts.CollateralVaultAave.Wiring

open Contracts
open Compiler.CompilationModel

/-- The contract declares exactly one external dependency: Aave `IPool.supply`. -/
theorem external_is_IPool_supply :
    (CollateralVaultAave.spec.externals).map (·.name) = ["IPool.supply"] := by decide

/-- `deposit` issues that call: a state-writing `externalCallWithReturn` ECM with 5 args
    (pool address + `asset`, `amount`, `onBehalfOf`, `referralCode`). -/
theorem deposit_issues_supply_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallWithReturn" &&
                mod.numArgs == 5 &&
                mod.writesState &&
                args.length == 5
          | _ => false)) = true := by decide

end Contracts.CollateralVaultAave.Wiring
