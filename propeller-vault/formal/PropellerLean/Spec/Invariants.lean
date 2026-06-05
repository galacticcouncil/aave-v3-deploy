import PropellerLean.Spec.State

/-!
# Propeller — invariant predicates

The six invariants the Solidity `propeller-vault` checks under fuzzing (§8 of the
spec). Phase 1 defines them and the ones provable statically; Phase 2 proves the
rest are preserved across the transition system.
-/

namespace Propeller
namespace State

/-- **principalFloored.** The synthetic's risk-weighted value covers the Main debt:
`mainDebt ≤ synth·LTsynth`. The spec mints `synth = mainDebt/0.98 × 1.005` so this
holds with a 0.5% buffer. This is the single fact that floors `mainHF ≥ 1`. -/
def principalFloored (s : State) : Prop :=
  s.mainDebt ≤ s.synth * s.ltSynth

/-- **synthConserved (peg band).** The synthetic tracks the Main debt within a band:
never under (else the floor breaks) and never over by more than the buffer `ε`. -/
def pegBand (s : State) (ε : ℝ) : Prop :=
  s.mainDebt ≤ s.synth * s.ltSynth ∧ s.synth * s.ltSynth ≤ s.mainDebt * (1 + ε)

/-- **subLoopHF.** The PRIME loop stays at or above the de-lever trigger `t` (≈ 1.10). -/
def subLoopHealthy (s : State) (t : ℝ) : Prop :=
  t ≤ s.subHF

end State
end Propeller
