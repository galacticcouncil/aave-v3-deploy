# Phase 4 — EVM bridge spike (go/no-go)

**Date:** 2026-06-05 · **Verity:** lfglabs-dev/verity @ main (v0.1.0, MIT) · cloned read-only to `/tmp/verity-spike`.

## Verdict: **GO (qualified)** for Spike A (Verity-native).

Verity is materially more capable than its public landing page implied. Propeller's
contract surface is reachable in its **proved** fragment, with the Aave interaction
sitting on a documented, enforceable trust boundary (which is unavoidable for *any*
verified contract calling an external protocol).

## Evidence (what's actually in the repo)

| Propeller needs | Verity status | Source |
|---|---|---|
| WAD/RAY fixed-point math (HF, LTV, peg) | **Proved fragment**: `mulDivDown`/`mulDivUp`/`wMulDown`/`wDivUp`, `safeAdd/Sub/Mul/Div` | `capabilities.mdx` → "Fully expressible and verified" |
| `SyntheticToken` (ERC20 + restricted mint/burn) | **Verified example exists**: `Contracts/ERC20/` (ERC20 + Spec + Invariants + Proofs) | `Contracts/ERC20/ERC20.lean` |
| `CollateralVault` (ERC4626-ish, shares/assets, storage invariant) | **Verified example exists**: `Contracts/Vault/` with `Spec`, `Invariants`, `SpecProofs`; invariant `assets_supply_synced : storage 0 = storage 1`; sum-of-balances reasoning | `Contracts/Vault/Spec.lean` |
| Storage scalars + mappings (balances, debt, synth supply, escrow) | **Proved**: scalar slots, `mapping`/`mapping2`, struct mappings | `capabilities.mdx` |
| Keeper guards / access control (`onlyOwner`, `require`, custom errors) | **Proved**: `require`/`requireError`/`revertError`, `msgSender` | `Contracts/ERC20/ERC20.lean` (`onlyOwner`) |
| Aave calls `supply/borrow/repay/withdraw` | **Trust boundary**: typed `interface IERC20 …` → ECM (`Calls.withReturn`), differential-tested, axiomatized. Enforce/scope with `--deny-low-level-mechanics` + `--trust-report` | `docs/EXTERNAL_CALL_MODULES.md` |

## The two risks from the plan — resolved

1. **Loops (`forEach`) only partially proven.** *Does not bite.* Propeller is **gradual
   DCA, no flash, keeper-`pokeBorrow`/`pokeRepay`** — one tranche per transaction. The
   leverage "loop" is realized **across transactions**, not as an in-contract unbounded
   `for`. Each entrypoint does a single bounded step → stays in the proved fragment.

2. **Multi-contract / external-protocol calls "not demonstrated".** *Outdated.* ECMs +
   typed interfaces are real and shipped; the Aave surface is expressible. The honest
   limitation is that external-call **soundness is by-assumption** — so the on-chain
   "never liquidated" theorem is *conditional on the assumed Aave spec* (its liquidation
   rule + `getReserveData`). That is the correct trust boundary and is exactly what our
   ℝ-level `WellFormed` already encodes as hypotheses.

## How the Lean spec (Phases 1–3) maps onto Verity's three layers

- **Specification layer** ← our `Propeller/Spec` (the `State`, `principalFloored`,
  `floor_main_hf`, the peg/escrow/solvency invariants). In Verity these become
  `*_spec : ContractState → ContractState → Prop` transition relations + storage
  invariants — *the same shape we already wrote* (`s → s' → Prop`, cf. `Vault/Spec.lean`).
- **Implementation layer** ← a `verity_contract` whose arithmetic uses `mulDivUp` (mint
  the synthetic — **round up**, matching our Phase-3 conservative-rounding result) and
  `wDiv`/`mulDivDown` for HF.
- **Proof layer** ← Verity preservation proofs (`Vault/SpecProofs.lean` template) that
  the implementation meets the spec; our `tick_preserves_floor` / `principalFloored_refines`
  are the mathematical content these will discharge.
- **Compilation** ← Verity's proven `EDSL→IR→Yul` pipeline; `Yul→bytecode` via pinned
  `solc` (Cancun) — runs on Hydration's Osaka EVM (superset).

## Reachability artifact — `SyntheticToken` in the Verity EDSL

Faithful to `Contracts/ERC20/ERC20.lean`. The synthetic is an ERC20 whose mint/burn are
restricted to the vault (`onlyVault`), with LTV-0 semantics enforced off-chain by the
Aave reserve config (REQ-SYNTH) — on-chain it is just a soulbound balance.

```lean
verity_contract SyntheticToken where
  storage
    vaultSlot        : Address := slot 0   -- the sole minter/burner (CollateralVault)
    totalSupplySlot  : Uint256 := slot 1
    balancesSlot     : Address → Uint256 := slot 2

  constructor (vault : Address) := do
    setStorageAddr vaultSlot vault
    setStorage totalSupplySlot 0

  -- onlyVault guard (mirrors ERC20.onlyOwner)
  function mint (toAddr : Address, amount : Uint256) : Unit := do
    let sender ← msgSender
    let vault  ← getStorageAddr vaultSlot
    require (sender == vault) "SYNTH: only vault"
    let bal    ← getMapping balancesSlot toAddr
    let bal'   ← requireSomeUint (safeAdd bal amount) "SYNTH: balance overflow"
    let sup    ← getStorage totalSupplySlot
    let sup'   ← requireSomeUint (safeAdd sup amount) "SYNTH: supply overflow"
    setMapping balancesSlot toAddr bal'
    setStorage totalSupplySlot sup'

  function burn (fromAddr : Address, amount : Uint256) : Unit := do
    let sender ← msgSender
    let vault  ← getStorageAddr vaultSlot
    require (sender == vault) "SYNTH: only vault"
    let bal    ← getMapping balancesSlot fromAddr
    require (bal >= amount) "SYNTH: burn exceeds balance"
    let sup    ← getStorage totalSupplySlot
    setMapping balancesSlot fromAddr (sub bal amount)
    setStorage totalSupplySlot (sub sup amount)

  function balanceOf (addr : Address) : Uint256 := do
    let bal ← getMapping balancesSlot addr
    return bal

  function totalSupply () : Uint256 := do
    let sup ← getStorage totalSupplySlot
    return sup
```

**Spec/invariant it must satisfy (transition-relation form, our Phase-2 style):**

```lean
-- supply conservation: mint by `amount` raises both balance and total supply by `amount`
def mint_spec (toAddr : Address) (amount : Uint256) (s s' : ContractState) : Prop :=
  s'.storageMap 2 toAddr = add (s.storageMap 2 toAddr) amount ∧
  s'.storage 1          = add (s.storage 1) amount ∧
  onlyVault s
-- noSynthBorrow is a *config* fact (Aave LTV 0), not a contract obligation — see REQ-SYNTH.
```

## Decision & next steps

- **Adopt Spike A (Verity-native).** Promote `propeller-vault/formal/PropellerLean/Spec` to the
  spec-of-record; add Verity as a dep in a `formal/bridge/` sub-package (its own toolchain pin —
  Verity tracks a different Lean version, so keep it isolated from the ℝ-spec lib).
- **Order:** `SyntheticToken` (above) → `CollateralVault` (fork `Contracts/Vault`) →
  `SubLoop` (single-step `pokeBorrow`/`pokeRepay`) → `Harvester` (guards) → Aave typed
  interfaces as ECMs (`IPool.supply/borrow/repay/withdraw`).
- **Trust report:** compile every contract with `--deny-low-level-mechanics`
  `--deny-axiomatized-primitives` except the explicit Aave ECM surface; archive
  `--trust-report` so the "never-liquidated" theorem's external-call assumptions are
  auditable.
- **Caveat to state plainly:** the bytecode-level guarantee is *conditional* on (a) the
  assumed Aave ECM spec and (b) the unverified `Yul→bytecode` solc step — both standard,
  both enforced/recorded by Verity's flags.

**Spike B (verify existing Solidity) is the fallback** only if a `CollateralVault` port hits
a Verity expressiveness wall; nothing in this assessment suggests it will.
