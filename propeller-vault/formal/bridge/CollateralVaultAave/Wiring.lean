/-
  Machine-checked wiring facts for the Aave-wired CollateralVault.

  These `decide` proofs verify, against the compilation model the Verity compiler consumes, that
  `deposit` actually issues the Aave `IPool.supply` and `IPool.borrow` cross-contract calls (as
  `externalCallWithReturn` ECMs). Same verification standard Verity uses for its own typed-interface
  contracts (`Contracts/Smoke/InternalInterfaceSmoke.lean`). `decide` ⇒ no extra axioms.
-/

import Contracts.CollateralVaultAave.Contract

namespace Contracts.CollateralVaultAave.Wiring

open Contracts
open Compiler.CompilationModel

/-- The contract declares exactly two external dependencies, in order: Aave `IPool.supply`
    then `IPool.borrow`. -/
theorem externals_are_supply_then_borrow :
    (CollateralVaultAave.spec.externals).map (·.name) = ["IPool.supply", "IPool.borrow"] := by decide

/-- `deposit` issues the `supply` call: a state-writing `externalCallWithReturn` ECM with 5 args
    (pool + `asset`, `amount`, `onBehalfOf`, `referralCode`). -/
theorem deposit_issues_supply_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallWithReturn" && mod.numArgs == 5 && mod.writesState &&
                args.length == 5
          | _ => false)) = true := by decide

/-- `deposit` also issues the `borrow` call: a state-writing `externalCallWithReturn` ECM with 6 args
    (pool + `asset`, `amount`, `interestRateMode`, `referralCode`, `onBehalfOf`). -/
theorem deposit_issues_borrow_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallWithReturn" && mod.numArgs == 6 && mod.writesState &&
                args.length == 6
          | _ => false)) = true := by decide

/-- `deposit` issues exactly two external calls (supply + borrow), no more. -/
theorem deposit_issues_exactly_two_calls :
    ((CollateralVaultAave.spec.functions).filterMap (fun fn =>
      if fn.name == "deposit" then
        some ((fn.body.filter (fun stmt =>
          match stmt with | Stmt.ecm _ _ => true | _ => false)).length)
      else none)) = [2] := by decide

end Contracts.CollateralVaultAave.Wiring
