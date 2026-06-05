import PropellerLean.FixedPoint.Uint256
import PropellerLean.Spec.Floor

/-!
# Propeller — fixed-point refinement (Phase 3)

The bridge between the on-chain integer guard and the real-valued safety spec.

`principalFloored_refines` — if the **integer** `principalFloored` check (flooring
mul-div) passes, then the **real** `principalFloored` holds on the embedded state.
Floor division *underestimates* the synthetic's value, so satisfying the on-chain
guard is strictly stronger than the real inequality: rounding is conservative, and
the floor never rounds the wrong way.

`refined_floor_hf` — therefore the integer guard, via the real floor theorem,
delivers `mainHF ≥ 1` (modulo the real `WellFormed` side-conditions).
-/

namespace Propeller
namespace FixedPoint

open Propeller.State

theorem principalFloored_refines (s : IState) (h : s.principalFloored) :
    (s.toReal).principalFloored := by
  have hBps : (0 : ℝ) < (Bps : ℝ) := by norm_num [Bps]
  have hWad : (0 : ℝ) < (Wad : ℝ) := by norm_num [Wad]
  -- unpack the integer guard, cast through the flooring mul-div conservatively
  unfold IState.principalFloored IState.synthValueWad at h
  have H : (s.mainDebtWad : ℝ) ≤ (s.synthWad * s.ltSynthBps : ℝ) / (Bps : ℝ) := by
    calc (s.mainDebtWad : ℝ)
        ≤ ((s.synthWad * s.ltSynthBps / Bps : ℕ) : ℝ) := by exact_mod_cast h
      _ ≤ ((s.synthWad * s.ltSynthBps : ℕ) : ℝ) / (Bps : ℝ) := Nat.cast_div_le
      _ = (s.synthWad * s.ltSynthBps : ℝ) / (Bps : ℝ) := by push_cast; ring
  -- mainDebtWad * Bps ≤ synthWad * ltSynthBps  (clear the floor's denominator)
  rw [le_div_iff₀ hBps] at H
  have hWne : (Wad : ℝ) ≠ 0 := ne_of_gt hWad
  -- goal: real principalFloored on toReal
  show ((s.mainDebtWad : ℝ) / Wad) ≤ ((s.synthWad : ℝ) / Wad) * ((s.ltSynthBps : ℝ) / Bps)
  rw [div_mul_div_comm, le_div_iff₀ (by positivity : (0 : ℝ) < (Wad : ℝ) * (Bps : ℝ))]
  -- goal: (mainDebtWad/Wad) * (Wad*Bps) ≤ synthWad*ltSynthBps ; cancel Wad on the left
  have hcancel :
      (s.mainDebtWad : ℝ) / Wad * ((Wad : ℝ) * (Bps : ℝ)) = (s.mainDebtWad : ℝ) * Bps := by
    rw [div_mul_eq_mul_div, mul_comm (Wad : ℝ) (Bps : ℝ), ← mul_assoc, mul_div_assoc,
        div_self hWne, mul_one]
  rw [hcancel]
  exact H

/-- The integer guard implies the real Main health-factor floor, given the real-side
well-formedness conditions on the embedded state. -/
theorem refined_floor_hf (s : IState) (wf : WellFormed s.toReal)
    (h : s.principalFloored) :
    1 ≤ (s.toReal).mainHF :=
  floor_main_hf _ wf (principalFloored_refines s h)

end FixedPoint
end Propeller
