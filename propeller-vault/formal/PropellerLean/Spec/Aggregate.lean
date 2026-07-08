import PropellerLean.Spec.Invariants
import PropellerLean.Spec.Redemption

/-!
# Propeller — portfolio-aggregate invariants

The per-position invariants of `Invariants.lean` lift to the **whole book** of positions: if every
position is floored / peg-banded, then the aggregate synthetic value covers the aggregate Main debt
and never exceeds it by more than the spec buffer. This is the portfolio form of `synthConserved` —
the protocol cannot over-mint the synthetic *in aggregate*, so the reserve as a whole stays backed by
real Main debt (`Σ synthᵢ·LT ≤ (1+ε)·Σ mainDebtᵢ`).
-/

namespace Propeller
namespace State

/-- Aggregate Main HOLLAR debt across a book of positions. -/
def aggMainDebt (ps : List State) : ℝ := (ps.map State.mainDebt).sum

/-- Aggregate risk-weighted synthetic value across a book of positions. -/
def aggSynthValue (ps : List State) : ℝ := (ps.map (fun s => s.synth * s.ltSynth)).sum

/-- **Aggregate floor.** If every position is `principalFloored`, the portfolio's synthetic value
covers its total Main debt — the reserve backs the whole book, not just each position. -/
theorem agg_principalFloored : ∀ (ps : List State), (∀ s ∈ ps, s.principalFloored) →
    aggMainDebt ps ≤ aggSynthValue ps := by
  intro ps
  induction ps with
  | nil => intro _; simp [aggMainDebt, aggSynthValue]
  | cons p ps ih =>
      intro h
      simp only [aggMainDebt, aggSynthValue, List.map_cons, List.sum_cons]
      have hp := h p (List.mem_cons_self)
      have hrest := ih (fun s hs => h s (List.mem_cons_of_mem _ hs))
      simp only [aggMainDebt, aggSynthValue] at hrest
      unfold principalFloored at hp
      linarith

/-- **Aggregate `synthConserved` (no portfolio over-mint).** If every position sits in the peg band
`pegBand … ε`, the portfolio's total synthetic value never exceeds `(1+ε)` times its total Main debt
— the reserve as a whole can't be inflated past the debt it backs. -/
theorem agg_synthConserved : ∀ (ps : List State) (ε : ℝ), (∀ s ∈ ps, s.pegBand ε) →
    aggSynthValue ps ≤ aggMainDebt ps * (1 + ε) := by
  intro ps ε
  induction ps with
  | nil => intro _; simp [aggMainDebt, aggSynthValue]
  | cons p ps ih =>
      intro h
      simp only [aggMainDebt, aggSynthValue, List.map_cons, List.sum_cons]
      have hp := (h p (List.mem_cons_self)).2
      have hrest := ih (fun s hs => h s (List.mem_cons_of_mem _ hs))
      simp only [aggMainDebt, aggSynthValue] at hrest
      rw [add_mul]
      linarith

/-- The portfolio synthetic value is squeezed into the aggregate peg band: it covers the total debt
(lower) and never over-mints past the buffer (upper). -/
theorem agg_pegBand (ps : List State) (ε : ℝ) (h : ∀ s ∈ ps, s.pegBand ε) :
    aggMainDebt ps ≤ aggSynthValue ps ∧ aggSynthValue ps ≤ aggMainDebt ps * (1 + ε) :=
  ⟨agg_principalFloored ps (fun s hs => (h s hs).1), agg_synthConserved ps ε h⟩

/-- Aggregate collateral deposited across the book. -/
def aggColl (ps : List State) : ℝ := (ps.map State.coll).sum

/-- Aggregate collateral returned on a full unwind across the book. -/
noncomputable def aggCollReturned (ps : List State) : ℝ := (ps.map State.collateralReturned).sum

/-- **Portfolio redemption solvency.** If every position is `freedBacked`, the whole book returns at
least the collateral deposited into it — the principal-back guarantee at portfolio scale, not just
per position. The redemption-side mirror of `agg_synthConserved`. -/
theorem agg_collateral_out_ge_in : ∀ (ps : List State), (∀ s ∈ ps, s.freedBacked) →
    aggColl ps ≤ aggCollReturned ps := by
  intro ps
  induction ps with
  | nil => intro _; simp [aggColl, aggCollReturned]
  | cons p ps ih =>
      intro h
      simp only [aggColl, aggCollReturned, List.map_cons, List.sum_cons]
      have hp := collateral_out_ge_in p (h p (List.mem_cons_self))
      have hrest := ih (fun s hs => h s (List.mem_cons_of_mem _ hs))
      simp only [aggColl, aggCollReturned] at hrest
      linarith

end State
end Propeller
