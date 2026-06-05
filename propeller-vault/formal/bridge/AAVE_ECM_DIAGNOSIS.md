# Emitting Yul for the Aave-wired CollateralVault — diagnosis

> Upstream issues filed: blocker 1 → [lfglabs-dev/verity#1951](https://github.com/lfglabs-dev/verity/issues/1951),
> blocker 2 → [lfglabs-dev/verity#1952](https://github.com/lfglabs-dev/verity/issues/1952). Blocker 3 (CEI) is
> Verity working as intended ([#1728](https://github.com/lfglabs-dev/verity/issues/1728)).

Wiring `IPool.supply` into `CollateralVault.deposit` (a typed-interface ECM) and compiling it to Yul
hits **three stacked blockers** in Verity v0.1.0. All three are now understood; the wired `deposit`
does emit a real cross-contract `call` once they're addressed. This is why Verity's own suite never
compiles interface/ECM contracts to Yul (its canonical `contracts.manifest` contains only ECM-free
contracts — interface contracts are verified by `decide` only).

## 1. `evalConstCheck` — the CLI can't materialize the inlined ECM closure
`verity-compiler` (both the raw binary and `lake exe`) reads the manifest module at runtime and does
`unsafe env.evalConstCheck CompilationModel … spec` (`Compiler/ModuleInput.lean:69`). For an ECM
contract this throws *"Unable to evaluate '…spec' as CompilationModel"*.

- The `verity_contract` macro **inlines** the ECM (`externalCallWithReturn` builds an
  `ExternalCallModule` whose `compile` field is a closure capturing the selector) directly into the
  `spec` constant — `externalCallWithReturn` isn't even in the imported environment.
- The spec **is valid**: `evalConstCheck` on it returns `.ok` during Lean *elaboration*
  (`lake env lean` `run_cmd`), and `#eval` reads its fields fine. Only the standalone binary's
  *dynamic* runtime eval fails to materialize the embedded closure.
- **Bypass:** reference `spec` *statically* in a tiny emit program and call the codegen directly —
  no dynamic `evalConstCheck`:
  ```
  let spec := Contracts.CollateralVaultAave.spec
  let sel  ← Compiler.Selector.computeSelectors spec
  let ir   ← Compiler.CompilationModel.compile spec sel      -- Except String IRContract
  IO.FS.writeFile "out.yul" (Compiler.Yul.render (Compiler.CodegenCommon.emitYul ir))
  ```

## 2. External name validated as a Yul identifier — dotted ABI names rejected
Next: *"external declaration name must be a valid identifier: IPool.supply"*.
`Compiler/CompilationModel/ValidationCalls.lean:843` runs `ensureContractIdentifier "external
declaration" ext.name` over **every** external. A typed-interface ABI external's name is the dotted
label `IPool.supply`, which `Compiler.isValidIdentifier` rejects.

- This label is only an **audit identifier** — the `externalCallWithReturn` ECM emits the call by
  *selector* (`shl(224, 0x…)` + `call(...)`), never using the name as a Yul identifier. So the check
  is over-strict for ABI-boundary externals (it's correct for object-linked Yul libs like
  `PoseidonT3_hash`).
- **Upstream fix (one line):** skip / relax `ensureContractIdentifier` for externals whose name
  contains `.` (ABI-interface externals). Confirmed locally with that change (a throwaway patch, **not
  committed** — Verity is an external dep). Worth an upstream issue.

## 3. CEI enforcement — state writes after an external call are rejected
Then: *"function 'deposit' violates CEI (Checks-Effects-Interactions) ordering: state write after
external call"* (Verity issue #1728). This is a **real security guard**, and it caught a genuine
reentrancy hazard in the first draft (which called `pool.supply` before the share writes).

- **Fix (correct, committed):** order **effects before the interaction** — do the share/asset/supply
  storage writes, then `pool.supply` last. `CollateralVaultAave/Contract.lean` is now CEI-compliant.

## Result
With (1) the static emit path, (2) the external-identifier relaxation, and (3) CEI-correct ordering,
`deposit` compiles to `yul/CollateralVaultAave.yul`, whose runtime body is:

```
sstore(mappingSlot(2, sender), newShares)      // effects
sstore(0, newAssets)
sstore(1, newSupply)
…
mstore(__ecwr_ptr, shl(224, 0xe9c7359c))       // supply selector
mstore(add(__ecwr_ptr, 4),   asset)
mstore(add(__ecwr_ptr, 36),  assets)
mstore(add(__ecwr_ptr, 68),  onBehalfOf)
mstore(add(__ecwr_ptr, 100), 0)                // referralCode
let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 132, __ecwr_ptr, 32)   // interaction
if iszero(__ecwr_success) { …revert with bubbled returndata… }
```

## Caveats for real Aave integration
- **Selector mismatch:** emitted `0xe9c7359c` = `supply(address,uint256,address,uint256)`. Real Aave
  V3 is `supply(address,uint256,address,uint16)` → `0x617ba037`. Verity lacks `uint16`, so
  `referralCode` was modelled as `Uint256`. A correct integration needs `uint16` support (or a
  hand-tuned selector) for ABI compatibility.
- **Trust boundary:** the call is sound *by assumption* on Aave's spec; `writesState ⇒` the wired
  variant's accounting is conditional (no reentrancy / Aave doesn't mutate our slots). The pure
  `CollateralVault/` keeps its unconditional axiom-clean proof.

## What's committed vs not
- **Committed:** the CEI-correct `CollateralVaultAave/Contract.lean`, the `decide`-checked
  `Wiring.lean`, and `yul/CollateralVaultAave.yul` (with provenance header).
- **Not committed:** the throwaway one-line relaxation of `ValidationCalls.lean` (lives only in the
  local Verity checkout) and the emit script — both reproducible from this doc.
