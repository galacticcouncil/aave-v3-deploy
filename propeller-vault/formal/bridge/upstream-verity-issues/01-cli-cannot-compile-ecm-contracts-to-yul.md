# `verity-compiler` cannot compile typed-interface / ECM contracts to Yul — `evalConstCheck` fails on the macro-inlined ECM closure

## Summary
Running `verity-compiler --manifest <m> --output <dir>` on any contract that uses a typed `interfaces`
block (i.e. whose `spec` contains an `externalCallWithReturn` ECM) aborts with:

```
uncaught exception: Unable to evaluate '<Module>.spec' as Compiler.CompilationModel.CompilationModel
```

The `spec` itself is valid — it evaluates correctly during Lean elaboration and via `#eval`. Only the
standalone compiler's *runtime* `evalConstCheck` fails to materialize it. Net effect: ECM/interface
contracts can be written, type-checked, and `decide`-verified, but **cannot be lowered to Yul through
the standard CLI**. (Consistent with this: `packages/verity-examples/contracts.manifest` contains only
ECM-free contracts; the typed-interface examples are exercised by `decide` smoke tests, never compiled.)

## Repro
Minimal interface contract:
```lean
import Contracts.Common
namespace Contracts
open Verity hiding pure bind
open Verity.EVM.Uint256
open Verity.Stdlib.Math

verity_contract IfaceSmoke where
  storage
    xSlot : Uint256 := slot 0
  interfaces
    interface IPool where
      function supply(Address, Uint256, Address, Uint256) returns (Bool)
    end
  function poke (pool : IPool, asset : Address, onBehalfOf : Address, amt : Uint256) : Unit := do
    setStorage xSlot amt
    let _ok ← pool.supply asset amt onBehalfOf 0
end Contracts
```
Register in the `Contracts` lib glob, add an aggregator `Contracts/IfaceSmoke.lean`
(`import Contracts.IfaceSmoke.Contract` …), then:
```sh
echo 'Contracts.IfaceSmoke' > iface.manifest
lake build Contracts.IfaceSmoke
./.lake/build/bin/verity-compiler --manifest iface.manifest --output out   # ← throws
lake exe verity-compiler --manifest iface.manifest --output out            # ← same throw
```

## Evidence the spec is valid
- `#eval IfaceSmoke.spec.externals.map (·.name)` ⇒ `["IPool.supply"]`.
- `evalConstCheck` **succeeds** when run inside Lean elaboration:
  ```lean
  run_cmd do
    let env ← Lean.getEnv
    match unsafe env.evalConstCheck Compiler.CompilationModel.CompilationModel ({})
        ``Compiler.CompilationModel.CompilationModel ``Contracts.IfaceSmoke.spec with
    | .ok _    => Lean.logInfo "OK"        -- ← this branch is taken
    | .error e => Lean.logError e
  ```
- Importing *only* the aggregator module, `env.contains \`Compiler.Modules.Calls.externalCallWithReturn`
  is `false` — i.e. the macro **inlines** the ECM (`externalCallWithReturn` returns an
  `ExternalCallModule` whose `compile` field is a closure capturing the selector) rather than
  referencing a named constant.

## Likely cause
`Compiler/ModuleInput.lean:69` does `unsafe env.evalConstCheck CompilationModel opts … specName` on the
freshly-imported environment. The `spec` value embeds the ECM's `compile : CompilationContext →
List YulExpr → Except String (List YulStmt)` closure inline. The standalone binary's runtime
`evalConst` appears unable to materialize that closure from the imported `.olean` alone, whereas the
elaborator's interpreter can. So compilation aborts before codegen even runs.

## Workaround (confirms it's only this entry point)
Bypassing the dynamic lookup — referencing `spec` *statically* and calling the codegen directly — works
and emits Yul:
```lean
def main : IO Unit := do
  let spec := Contracts.IfaceSmoke.spec
  let sel  ← Compiler.Selector.computeSelectors spec
  match Compiler.CompilationModel.compile spec sel with
  | .ok ir   => IO.FS.writeFile "out.yul" (Compiler.Yul.render (Compiler.CodegenCommon.emitYul ir))
  | .error e => IO.eprintln e
-- lake env lean --run emit.lean
```
(Two further blockers then surface — see the sibling issue on dotted external-name validation, and CEI
ordering enforcement #1728 — but those are *after* codegen starts.)

## Suggested fixes (any one)
- Have the CLI obtain the spec without runtime `evalConstCheck` of an inlined-closure value — e.g. a
  generated `@[extern]`/compiled accessor, or a codegen entry that takes the spec by static reference.
- Or have the macro emit the ECM as a reference to a named, compiled `ExternalCallModule` constant
  (instead of inlining the `compile` closure), so `evalConstCheck` can materialize it at runtime.
- At minimum: document that typed-interface/ECM contracts are not compilable via the standard CLI in
  this release, and ship the static-reference emit path as a supported entry point.

## Environment
Verity `23e46d2` (v0.1.0), EVMYulLean `7785a9b`, Lean `v4.22.0`, Linux x86_64.
