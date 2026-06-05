# External-declaration identifier validation rejects typed-interface ABI externals (dotted names like `IPool.supply`)

## Summary
Compiling a contract that calls a typed-interface method fails validation with:

```
Compilation error: external declaration name must be a valid identifier: IPool.supply
```

`validateCalls` runs `ensureContractIdentifier "external declaration" ext.name` over **every** entry of
`spec.externals` (`Compiler/CompilationModel/ValidationCalls.lean:843`). A typed-interface ABI external
is named `<Interface>.<method>` (e.g. `IPool.supply`); `Compiler.isValidIdentifier`
(`Compiler/Identifier.lean:20`) rejects the `.`, so any ABI-boundary external call is rejected.

This check is appropriate for **object-linked** externals (e.g. `PoseidonT3_hash`), whose name *is*
emitted as a Yul function identifier at the link site. But for an **ABI-boundary** external the name is
only an audit/label string — the `externalCallWithReturn` ECM lowers the call by **selector**
(`mstore(ptr, shl(224, 0x…)); … call(gas(), target, …)`) and never uses the external's name as a Yul
identifier. So the identifier constraint is over-strict for this class of external.

## Repro
With the `evalConstCheck` blocker worked around (see sibling issue), compiling the `IfaceSmoke`/
`pool.supply(...)` contract reaches `validateCalls` and throws the message above.

## Root cause
```
-- Compiler/CompilationModel/ValidationCalls.lean:842
for ext in spec.externals do
  ensureContractIdentifier "external declaration" ext.name    -- rejects "IPool.supply"
```
`ext.name` for a typed-interface external is the dotted `Interface.method` label; `isValidIdentifier`
only permits `[A-Za-z_][A-Za-z0-9_]*`.

## Suggested fix
Distinguish ABI-boundary externals from object-linked ones and skip (or relax) the Yul-identifier check
for the former — they are never emitted as Yul identifiers. Concretely, either:
- gate the check on link mode (only validate `internal_yul`/`object_linked`/`inline` externals as
  identifiers, not ABI-call externals); or
- allow `.` in `ext.name` specifically for interface-derived externals (the dotted `Interface.method`
  form is the intended, unique audit label).

Confirmed locally: skipping the check for `ext.name.contains '.'` lets codegen proceed and emit a
correct `call(gas(), pool, 0, …)` for `IPool.supply` (with the expected selector-based calldata).

## Related (not a bug)
Once this passes, Verity's **CEI enforcement** (#1728) correctly rejects `state write after external
call` if effects follow the interaction — a useful guard, resolved by ordering effects before the
external call. No change requested there.

## Environment
Verity `23e46d2` (v0.1.0), EVMYulLean `7785a9b`, Lean `v4.22.0`, Linux x86_64.
