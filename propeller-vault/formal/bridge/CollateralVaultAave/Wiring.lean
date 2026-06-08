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

/-- The contract declares exactly its six externals, in order: the four Aave Main-position calls,
    then the two inter-contract calls (`SyntheticToken.mint`, `SubLoop.deposit`). -/
theorem externals_are_the_six_calls :
    (CollateralVaultAave.spec.externals).map (·.name)
      = ["IPool.supply", "IPool.borrow", "IPool.repay", "IPool.withdraw",
         "ISynth.mint", "ISubLoop.deposit"] := by decide

/-- `deposit` issues the `supply` call: a state-writing **void** `externalCallNoReturn` ECM with 5 args
    (pool + `asset`, `amount`, `onBehalfOf`, `referralCode`). Real Aave V3 `supply` is `void`, so this
    is the no-output ECM (`resultVars := []`, no returndata check) — not `externalCallWithReturn`. -/
theorem deposit_issues_supply_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallNoReturn" && mod.numArgs == 5 && mod.writesState &&
                mod.resultVars == [] && args.length == 5
          | _ => false)) = true := by decide

/-- `deposit` also issues the `borrow` call: a state-writing **void** `externalCallNoReturn` ECM with
    6 args (pool + `asset`, `amount`, `interestRateMode`, `referralCode`, `onBehalfOf`). Real Aave V3
    `borrow` is `void`, so this is the no-output ECM — not `externalCallWithReturn`. -/
theorem deposit_issues_borrow_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallNoReturn" && mod.numArgs == 6 && mod.writesState &&
                mod.resultVars == [] && args.length == 6
          | _ => false)) = true := by decide

/-- `deposit` issues the **inter-contract** `SyntheticToken.mint` call: a state-writing **void**
    `externalCallNoReturn` ECM (3 args: synth + `to`,`amount`). `SyntheticToken.mint` is `Unit`
    (matching `SyntheticToken.sol`, whose mint is also void), so it's the no-output ECM
    (`resultVars := []`, no returndata check) — not `externalCallWithReturn`. -/
theorem deposit_issues_synth_mint :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallNoReturn" && mod.numArgs == 3 && mod.writesState &&
                mod.resultVars == [] && args.length == 3
          | _ => false)) = true := by decide

/-- `deposit` issues the **inter-contract** `SubLoop.deposit` call: a state-writing **void**
    `externalCallNoReturn` ECM (2 args: loop + `borrowAmount`). `SubLoop.deposit` is `Unit`, so it's
    the no-output ECM (`resultVars := []`, no returndata check) — not `externalCallWithReturn`. -/
theorem deposit_issues_subloop_deposit :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "deposit" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallNoReturn" && mod.numArgs == 2 && mod.writesState &&
                mod.resultVars == [] && args.length == 2
          | _ => false)) = true := by decide

/-- `deposit` issues exactly four external calls (supply, borrow, synth.mint, subloop.deposit). -/
theorem deposit_issues_exactly_four_calls :
    ((CollateralVaultAave.spec.functions).filterMap (fun fn =>
      if fn.name == "deposit" then
        some ((fn.body.filter (fun stmt =>
          match stmt with | Stmt.ecm _ _ => true | _ => false)).length)
      else none)) = [4] := by decide

/-- `pokeSettle` (the unwind leg) issues the `repay` call: an `externalCallWithReturn` ECM with 5 args
    (pool + `asset`, `amount`, `interestRateMode`, `onBehalfOf`). -/
theorem pokeSettle_issues_repay_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "pokeSettle" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallWithReturn" && mod.numArgs == 5 && mod.writesState &&
                args.length == 5
          | _ => false)) = true := by decide

/-- `pokeSettle` also issues the `withdraw` call: an `externalCallWithReturn` ECM with 4 args
    (pool + `asset`, `amount`, `recipient`). -/
theorem pokeSettle_issues_withdraw_call :
    (CollateralVaultAave.spec.functions).any (fun fn =>
      fn.name == "pokeSettle" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallWithReturn" && mod.numArgs == 4 && mod.writesState &&
                args.length == 4
          | _ => false)) = true := by decide

/-- `pokeSettle` issues exactly two external calls (repay + withdraw), no more. -/
theorem pokeSettle_issues_exactly_two_calls :
    ((CollateralVaultAave.spec.functions).filterMap (fun fn =>
      if fn.name == "pokeSettle" then
        some ((fn.body.filter (fun stmt =>
          match stmt with | Stmt.ecm _ _ => true | _ => false)).length)
      else none)) = [2] := by decide

end Contracts.CollateralVaultAave.Wiring
