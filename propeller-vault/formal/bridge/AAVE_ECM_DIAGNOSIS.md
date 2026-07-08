# Compiling the Aave-wired CollateralVault to Yul — diagnosis (RESOLVED)

Wiring `IPool.supply/borrow/repay/withdraw` into `CollateralVaultAave` (typed-interface ECMs) and
compiling it to Yul surfaced **three stacked blockers** in stock Verity v0.1.0. **Two were real
compiler bugs (now fixed and verified); the third is Verity working as intended.** With the two fixes
applied to the Verity checkout, the **stock `verity-compiler` CLI compiles the contract directly** —
639 lines of Yul, all four `call(gas(), pool, …)` sites, no workaround.

> Upstream issues: [verity#1951](https://github.com/lfglabs-dev/verity/issues/1951) (ECM→Yul) and
> [verity#1952](https://github.com/lfglabs-dev/verity/issues/1952) (dotted external name). Both fixed
> in a local Verity checkout (changes are upstream-Verity source — to be PR'd, not in this repo).
> Blocker 3 (CEI) is Verity working as intended ([verity#1728](https://github.com/lfglabs-dev/verity/issues/1728)).

## 1. CLI couldn't evaluate the ECM spec — `loadExts` + `supportInterpreter`  *(verity#1951, FIXED)*
`verity-compiler` aborted with *"Unable to evaluate '<Module>.spec' as CompilationModel"* on any
contract whose `spec` contains an `externalCallWithReturn` ECM. **Two root causes**, both fixed:

1. `Compiler/ModuleInput.lean` — `importModules … {}` ran with `loadExts` defaulting to **false**, so
   environment extensions (incl. the compiler-IR extension) weren't populated, and `evalConstCheck`
   couldn't materialize a spec that *applies a function* (`withReturnModule`). Non-ECM specs use only
   inductive constructors, so they reduced fine. **Fix:** `importModules … (loadExts := true)`.
2. `lakefile.lean` — `lean_exe «verity-compiler»` lacked `supportInterpreter := true`; once extensions
   load, ECM spec-eval forces `Init`/`Std` decls (`UInt64.ofNatLT`) the interpreter needs. **Fix:** add it.

> Correction: an earlier draft of this doc (and of verity#1951) hypothesized the macro *inlined* the
> ECM `compile` closure and that the binary couldn't materialize it. **That was wrong** — the spec
> references `withReturnModule` *by name*. The two flags above are the actual fix. The
> static-reference emit script previously documented here is **obsolete**; the stock CLI now works.

## 2. External name validated as a Yul identifier — dotted ABI names rejected  *(verity#1952, FIXED)*
Next: *"external declaration name must be a valid identifier: IPool.supply"*.
`Compiler/CompilationModel/ValidationCalls.lean` validated every external's name as a Yul identifier,
but a typed-interface ABI external carries a dotted `Interface.method` audit label that is **never
emitted as a Yul identifier** (the ECM lowers by selector). **Fix:** skip the check for dotted names
(`unless ext.name.contains '.'`), keeping it for object-linked externals (e.g. `PoseidonT3_hash`).

## 3. CEI enforcement — state writes after an external call  *(verity#1728, working as intended)*
*"function 'deposit' violates CEI ordering: state write after external call."* A real security guard;
it caught a genuine reentrancy hazard in the first draft (which supplied before writing shares).
**Resolved correctly** by ordering effects before interactions.

### 3b. Multiple external calls (supply→borrow, repay→withdraw) — `allow_post_interaction_writes`
A **second** writing-ECM after the first call re-triggers CEI (`CEIEcmWriteAfterCallRejected`) because
`externalCallWithReturn` is `writesState`. Both multi-call functions (`deposit`, `pokeSettle`) carry
the `allow_post_interaction_writes` annotation. **Justified:** every storage write precedes all calls;
the only thing after the first call is the next call to the same trusted pool, with no storage write
after either. Arguably over-conservative when the post-call "write" is itself a call, but a sound
escape hatch exists, so *not* filed as a bug.

## Result
Stock `verity-compiler --manifest contracts.manifest` emits `yul/CollateralVaultAave.yul`:
`deposit` = effects → `supply` → `borrow`; `pokeSettle` = effects → `repay` → `withdraw`. Each is a
real `call(gas(), pool, 0, ptr, len, ptr, 32)` with selector-encoded calldata and bubbled-returndata
revert handling.

## Selector fidelity
- **All six selectors now match mainnet** (`referralCode` declared `Uint16`): `supply` `0x617ba037`,
  `borrow` `0xa415bcad`, `repay` `0x573ade81`, `withdraw` `0x69328dec`, `mint` `0x40c10f19`, `deposit`
  `0xb6b55f25`. The earlier `uint16→Uint256` mismatch is closed; calldata is byte-identical to live Aave.
  The void-return point is also closed: `supply`/`borrow` are declared void and lower to the no-return
  ECM (`externalCallNoReturn`, no returndatasize check) via verity PR #1957 — see `forktest/README.md`.

Historical note (pre-fix):
- **ABI-exact** (no `uint16`): `repay(address,uint256,uint256,address)` → `0x573ade81`,
  `withdraw(address,uint256,address)` → `0x69328dec` — match mainnet Aave V3.
- **Differ** (model `uint16 referralCode` as `Uint256`, Verity lacks `uint16`): `supply` → `0xe9c7359c`
  (mainnet `0x617ba037`), `borrow` → `0xa2b86e7b` (mainnet `0xa415bcad`). Needs `uint16` support (or a
  hand-tuned selector) for those two.

## Trust boundary
Each call is sound *by assumption* on Aave's spec; `writesState ⇒` the wired variant's accounting is
conditional (no reentrancy / Aave doesn't mutate our slots). The pure `CollateralVault/` keeps its
unconditional axiom-clean proof. Compile with `--deny-low-level-mechanics` + `--trust-report`.

## What's committed vs not
- **Committed (this repo):** `CollateralVaultAave/Contract.lean`, the `decide`-checked `Wiring.lean`,
  and `yul/CollateralVaultAave.yul` (emitted by the **stock** CLI with the fixes applied).
- **Not committed (upstream Verity source):** the verity#1951 / #1952 fixes live in the local Verity
  checkout — to be submitted upstream as PRs against those issues.
