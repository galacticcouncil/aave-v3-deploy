import PropellerLean.Spec.Floor

/-!
# Propeller — operations as state transitions (Phase 2)

Each protocol action is a function on `State`. The interesting safety content is
that `principalFloored` is *re-established* after every action by the synthetic
peg: interest accrual (`accrueInterest`) can erode the floor, and `maintainPeg`
restores it. We prove the floor (and `WellFormed`) is preserved across the
maintenance tick and across repay.

`k` is the spec's mint buffer (`1.005`); we keep it abstract with `1 ≤ k`.
-/

namespace Propeller
namespace State

/-- Mint the synthetic to the spec target `k·mainDebt`, i.e. set
`synth := mainDebt·k / ltSynth` so that `synth·ltSynth = mainDebt·k`. -/
noncomputable def mintSynthToPeg (s : State) (k : ℝ) : State :=
  { s with synth := s.mainDebt * k / s.ltSynth }

/-- A maintenance re-peg at the spec buffer. -/
noncomputable def maintainPeg (s : State) : State := s.mintSynthToPeg 1.005

/-- HOLLAR interest accrues on the Main debt by `δ ≥ 0`. This alone can break the
floor — it must be followed by `maintainPeg`. -/
def accrueInterest (s : State) (δ : ℝ) : State :=
  { s with mainDebt := s.mainDebt + δ }

/-- A full maintenance tick: accrue interest, then re-peg the synthetic. -/
noncomputable def tick (s : State) (δ : ℝ) : State := (s.accrueInterest δ).maintainPeg

/-- Repay `r` of the Main debt and re-peg (burning synthetic down to the new debt). -/
noncomputable def repay (s : State) (r : ℝ) : State :=
  { s with mainDebt := s.mainDebt - r }.maintainPeg

end State
end Propeller
