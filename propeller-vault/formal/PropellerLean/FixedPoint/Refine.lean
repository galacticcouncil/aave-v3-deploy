import PropellerLean.FixedPoint.Uint256
import PropellerLean.Spec.Floor
import PropellerLean.Spec.SubLoop

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

/-! ## Loop-side refinement (`freedBacked`, `accrueLoop`)

The same conservative-rounding bridge for the loop: the on-chain loop-collateral value uses a
**flooring** WAD mul-div, which *underestimates* the true `primeAmt·primePrice`, so passing the
integer `freedBacked` guard is strictly stronger than the real inequality. And the on-chain
`accrueLoop` (integer add to `primeAmtWad`) **refines** the spec's `State.accrueLoop` exactly: the
embedding commutes, `(s.accrueLoop g).toReal = (s.toReal).accrueLoop (g/Wad)`. -/

theorem freedBacked_refines (s : IState) (h : s.freedBacked) : (s.toReal).freedBacked := by
  have hWad : (0 : ℝ) < (Wad : ℝ) := by norm_num [Wad]
  unfold IState.freedBacked IState.loopCollWad at h
  -- cast the floored product up, conservatively: floor ≤ real quotient
  have H : (s.mainDebtWad : ℝ) + (s.subDebtWad : ℝ)
      ≤ (s.primeAmtWad : ℝ) * (s.primePriceWad : ℝ) / Wad := by
    calc (s.mainDebtWad : ℝ) + (s.subDebtWad : ℝ)
        = ((s.mainDebtWad + s.subDebtWad : ℕ) : ℝ) := by push_cast; ring
      _ ≤ ((s.primeAmtWad * s.primePriceWad / Wad : ℕ) : ℝ) := by exact_mod_cast h
      _ ≤ ((s.primeAmtWad * s.primePriceWad : ℕ) : ℝ) / Wad := Nat.cast_div_le
      _ = (s.primeAmtWad : ℝ) * (s.primePriceWad : ℝ) / Wad := by push_cast; ring
  -- goal: real freedBacked on the embedded state
  show ((s.mainDebtWad : ℝ) / Wad)
      ≤ ((s.primeAmtWad : ℝ) / Wad) * ((s.primePriceWad : ℝ) / Wad) - (s.subDebtWad : ℝ) / Wad
  rw [le_sub_iff_add_le, ← add_div, div_mul_div_comm, ← div_div]
  gcongr

/-- **The on-chain `accrueLoop` refines the spec's.** Crediting `gWad` aPRIME on the integer state,
then embedding, equals embedding then crediting `gWad/Wad` aPRIME in the real spec — the refinement
diagram commutes. -/
theorem accrueLoop_toReal (s : IState) (gWad : ℕ) :
    (s.accrueLoop gWad).toReal = (s.toReal).accrueLoop ((gWad : ℝ) / Wad) := by
  unfold IState.accrueLoop IState.toReal State.accrueLoop
  congr 1
  push_cast
  ring

/-- **Loop refinement payoff.** If the integer `freedBacked` guard passes after on-chain yield, the
real spec state after the corresponding yield is `freedBacked`. -/
theorem accrueLoop_freedBacked_refines (s : IState) (gWad : ℕ)
    (h : (s.accrueLoop gWad).freedBacked) :
    ((s.toReal).accrueLoop ((gWad : ℝ) / Wad)).freedBacked := by
  rw [← accrueLoop_toReal]
  exact freedBacked_refines _ h

end FixedPoint
end Propeller
