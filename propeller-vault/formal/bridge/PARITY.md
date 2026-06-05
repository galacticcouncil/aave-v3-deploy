# Parity with the Solidity implementation

The Verity contracts in `bridge/` are a **formal reference model**, not a selector-compatible
re-implementation of `propeller-vault/src/*.sol`. The Solidity is the full product (redemption queue,
`tvlCap`, roles, `DEAD_SHARES`, `deleverTarget`, WAD/BPS math, `deposit(uint256,address)`); the Verity
model captures the core accounting + the cross-contract call structure with 1:1 simplifications and
interface params. So parity is **not** bytecode/ABI equivalence — it's checked at three levels.

## 1. Shared-invariant parity — the real bridge

The §8 invariants are validated **two independent ways** against the *same* named set: machine-proven
(Lean ℝ-spec + Verity), and fuzzed against the real Solidity. Coverage matrix:

| §8 invariant | Lean ℝ-spec (`formal/PropellerLean`) | Verity contract proof (`bridge/`) | Solidity fuzz (`test/invariant`) |
|---|---|---|---|
| `principalFloored` (synth·LT ≥ debt) | `floor_main_hf`, `peg_floored`, `tick_safe` | `Harvester.maintainPeg_restores_floor`; `SyntheticToken.mint_increases_supply` | `invariant_principalFloored` ✓ |
| `freedBacked` / collateral-out ≥ in | `collateral_out_ge_in` | (loop-equity side; vault settle) | `invariant_freedBacked` ✓ |
| `shareConservation` | share-accounting lemmas | `CollateralVault.{deposit,claim}_preserves_synced` (`assets==supply`) | `invariant_shareConservation` ✓ |
| `synthConserved` | `pegBand` | `SyntheticToken.{mint,burn}_*` (supply tracks mint/burn) | `invariant_synthConserved` ✓ |
| `escrow` | `claimShares_escrowOk` | `CollateralVault.claimShares_escrowOk` | `invariant_escrow` ✓ |
| `noSynthBorrow` | `synth_adds_no_borrow_power` | `SyntheticToken.synth_adds_no_borrow_power` (LTV-0 config) | `invariant_noSynthBorrow` ✓ |
| loop equity-neutrality | — (implementation-level) | `SubLoop.{pokeBorrow,pokeRepay}_equity_neutral` | (loop `ramp`/`churnUnwind` in handler) |
| keeper/controller auth | — | `pokeSettle_reverts_when_not_keeper`, `poke{Borrow,Repay}_reverts_when_not_controller` | `onlyRole(KEEPER_ROLE)` paths |

**Runnable evidence (both sides green):**
- Solidity: `forge test --match-path test/invariant/PropellerInvariant.t.sol` → **6/6 invariants pass**,
  256 runs each (~12,800 calls).
- Lean: `cd formal && lake build` → all spec theorems **axiom-clean, 0 `sorry`**; the Verity `decide`
  wiring + revert proofs depend on no extra axioms.

This is the parity of record: one invariant set, fuzzed on the deployable Solidity and proven over the
model. The invariant *names* line up one-to-one.

## 2. Differential / behavioral parity (runnable — `forktest/`, GREEN)

The Verity Yul is lowered to bytecode by stock `solc 0.8.33` and deployed in a Foundry test
(`test/formal/VerityParity.t.sol`); `deposit` runs against mocks mirroring the emitted selectors and
**every cross-contract call + accounting slot is asserted**:
```
forge test --match-path test/formal/VerityParity.t.sol --evm-version shanghai
  [PASS] test_deposit_wires_all_calls · [PASS] test_pokeSettle_onlyKeeper
```
(`--evm-version shanghai`+ because the bytecode uses `PUSH0`; under default `paris` it self-skips, so
the main suite stays green. Hydration is Osaka.) This validates the *actual emitted bytecode* — deploy,
selector dispatch, ABI-encoded cross-contract calls, storage evolution, and the `onlyKeeper` guard.

Remaining limits (for a *real-Aave fork*, not the mock harness):
- **Selector mismatch:** `MockPool` implements the real Aave `uint16` selectors (`supply` `0x617ba037`,
  `borrow` `0xa415bcad`); Verity emits `uint16→uint256` ones (`0xe9c7359c`/`0xa2b86e7b`). So the Verity
  bytecode's supply/borrow calls don't reach `MockPool` until the upstream `uint16` fix
  (verity PRs #1953/#1954 land the compile path; the `uint16` ABI point is still open). `repay`
  (`0x573ade81`) / `withdraw` (`0x69328dec`) and the inter-contract `mint`/`deposit`/`pokeRepay`
  selectors already match.
- **ABI differences:** the Verity `deposit` takes interface params; the Solidity `deposit(assets,
  receiver)` reads a stored registry. So differential testing compares the *internal accounting state*
  (`totalAssets`/`totalSupply`/share balances/`mainDebt`), not call-for-call ABI behaviour.
- **solc:** the Verity Yul needs a standalone `solc` (0.8.33, Verity's pin) to lower to bytecode;
  Foundry's managed solc covers the Solidity side only.

## 3. Selector / ABI parity — N/A

The Verity vault has its own entrypoint signatures (a model), so it is not a drop-in, selector-compatible
replacement. If a drop-in is ever wanted, align the Verity entrypoint signatures + storage layout with the
Solidity and add a `vm.load` storage-slot differential — out of scope for the reference model.

## Bottom line

Parity today = **shared-invariant parity** (level 1, named one-to-one, green on both sides) **plus a
runnable level-2 differential test** of the emitted bytecode (green against selector-mirroring mocks).
A real-Aave *fork* run is one mock-swap away once the upstream `uint16` selector point is closed;
level-3 ABI drop-in is not a goal for a reference model.
