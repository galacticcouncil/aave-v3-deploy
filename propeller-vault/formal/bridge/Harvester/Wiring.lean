/-
  Machine-checked wiring for the Harvester → SubLoop inter-contract call.
  `decide` ⇒ no axioms; same standard Verity uses for typed-interface contracts.
-/

import Contracts.Harvester.Contract

namespace Contracts.Harvester.Wiring

open Contracts
open Compiler.CompilationModel

/-- The Harvester's sole external dependency is `SubLoop.pokeRepay`. -/
theorem external_is_subloop_pokeRepay :
    (Harvester.spec.externals).map (·.name) = ["ISubLoop.pokeRepay"] := by decide

/-- `deLeverLoop` issues that call: a state-writing `externalCallWithReturn` ECM with 2 args
    (loop address + `amount`). -/
theorem deLeverLoop_issues_pokeRepay :
    (Harvester.spec.functions).any (fun fn =>
      fn.name == "deLeverLoop" &&
        fn.body.any (fun stmt =>
          match stmt with
          | Stmt.ecm mod args =>
              mod.name == "externalCallWithReturn" && mod.numArgs == 2 && mod.writesState &&
                args.length == 2
          | _ => false)) = true := by decide

end Contracts.Harvester.Wiring
