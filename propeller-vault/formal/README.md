# propeller-vault — Lean 4 formal spec

Formal verification of **Propeller** — a protocol-managed leveraged-yield product on
Hydration — in **Lean 4**. Turns the invariants currently checked only by the Solidity fuzz
tests (`../test/invariant/`) into machine-checked theorems over *all* inputs.

Lives beside the contracts it models: `propeller-vault/{src,test,formal}` (branch `propeller`).
A self-contained Lake project; the Foundry build ignores it and vice-versa.
Strategy and rationale: `~/.claude/plans/lets-plan-implementation-of-warm-zebra.md` (Path C).

## Layout

```
PropellerLean/
├─ Spec/
│  ├─ State.lean         balance-sheet State, mainHF / borrowCapacity / subHF, WellFormed
│  ├─ Invariants.lean    principalFloored, pegBand, subLoopHealthy
│  ├─ Floor.lean         Phase 1: the "never liquidated" theorems
│  ├─ Ops.lean           transitions: mintSynthToPeg, maintainPeg, accrueInterest, tick, repay
│  ├─ Preservation.lean  Phase 2: invariant preservation; tick_safe (HF≥1 after every tick)
│  └─ Redemption.lean    Phase 2: escrow / shareConservation / freedBacked → collateral_out_ge_in
└─ FixedPoint/
   ├─ Uint256.lean       WAD/bps integer model (what Solidity stores)
   └─ Refine.lean        Phase 3: integer floor guard conservatively refines the real floor
```

`BRIDGE_SPIKE.md` — Phase 4 EVM bridge go/no-go (Verity-native; **GO, qualified**).

## Headline results (all machine-checked, 0 `sorry`, axioms = `propext`/`Classical.choice`/`Quot.sound` only)

| Theorem | Claim |
|---|---|
| `floor_main_hf` | `principalFloored ⟹ mainHF ≥ 1` |
| `never_liquidated_at_any_price` | the floor holds at **every** price `p ≥ 0`, incl. `p = 0` |
| `peg_floored` | the spec mint rule (`synth·LT = mainDebt·k`, `k ≥ 1`) establishes the floor |
| `synth_adds_no_borrow_power` | the synthetic (LTV 0) grants zero borrow power (`noSynthBorrow`) |
| `tick_safe` | a maintenance tick (accrue interest → re-peg) lands at `mainHF ≥ 1` |
| `collateral_out_ge_in` | under `freedBacked`, settlement returns ≥ the deposited collateral |
| `claimShares_escrowOk` | escrow stays a non-negative subset of shares (`escrow`) |
| `principalFloored_refines` | the on-chain integer floor guard conservatively implies the real floor |

## Build & verify

```sh
. ~/.elan/env
lake build
# integrity gate:
echo 'import PropellerLean
#print axioms Propeller.State.floor_main_hf
#print axioms Propeller.FixedPoint.principalFloored_refines' | lake env lean /dev/stdin
```

Toolchain: Lean `v4.30.0` + Mathlib `v4.30.0` (pinned in `lean-toolchain` / `lakefile.toml`).
