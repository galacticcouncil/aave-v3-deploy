import PropellerLean.Spec.Ops

/-!
# Propeller — invariant preservation (Phase 2)

The safety invariant `principalFloored` is *re-established* by the synthetic peg
after every state-changing action. We prove:

* `mintSynthToPeg_floors` — pegging to `k·mainDebt` (`k ≥ 1`) floors the principal.
* `maintainPeg_floors` — the maintenance re-peg floors it (spec buffer `1.005`).
* `tick_preserves_floor` — a full tick (accrue interest, then re-peg) lands floored,
  *from any prior state* — interest accrual can never strand the principal.
* `repay_preserves_floor` — repay-then-peg lands floored.
* `*_wellFormed` — each lands in a `WellFormed` state.

Combined with `floor_main_hf`, every reachable state has `mainHF ≥ 1`.
-/

namespace Propeller
namespace State

/-- Pegging the synthetic to `k·mainDebt` (with `k ≥ 1`) establishes the floor. -/
theorem mintSynthToPeg_floors (s : State) (k : ℝ)
    (hk : 1 ≤ k) (hd : 0 ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.mintSynthToPeg k).principalFloored := by
  simp only [principalFloored, mintSynthToPeg]
  have hcancel : s.mainDebt * k / s.ltSynth * s.ltSynth = s.mainDebt * k :=
    div_mul_cancel₀ (s.mainDebt * k) (ne_of_gt hlt)
  rw [hcancel]
  nlinarith [hd, hk]

/-- The maintenance re-peg floors the principal. -/
theorem maintainPeg_floors (s : State)
    (hd : 0 ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    s.maintainPeg.principalFloored :=
  mintSynthToPeg_floors s 1.005 (by norm_num) hd hlt

/-- A full maintenance tick (accrue `δ ≥ 0`, then re-peg) lands floored — regardless
of whether the prior state was floored. Interest accrual can never strand principal. -/
theorem tick_preserves_floor (s : State) (δ : ℝ)
    (hδ : 0 ≤ δ) (hd : 0 < s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.tick δ).principalFloored := by
  unfold tick
  apply maintainPeg_floors
  · -- (accrueInterest δ).mainDebt = mainDebt + δ ≥ 0
    simp only [accrueInterest]
    linarith
  · simpa [accrueInterest] using hlt

/-- Repay `r` (`0 ≤ r ≤ mainDebt`) then re-peg: lands floored. -/
theorem repay_preserves_floor (s : State) (r : ℝ)
    (_hr0 : 0 ≤ r) (hr : r ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.repay r).principalFloored := by
  unfold repay
  apply maintainPeg_floors
  · simp only; linarith
  · simpa using hlt

/-- The maintenance re-peg lands in a `WellFormed` state (only `synth` changes, and
the new `synth = mainDebt·1.005/ltSynth ≥ 0`). -/
theorem maintainPeg_wellFormed (s : State) (wf : WellFormed s) :
    WellFormed s.maintainPeg := by
  refine
    { coll_nonneg    := wf.coll_nonneg
      price_nonneg   := wf.price_nonneg
      ltColl_nonneg  := wf.ltColl_nonneg
      ltColl_le_one  := wf.ltColl_le_one
      ltSynth_pos    := wf.ltSynth_pos
      synth_nonneg   := ?_
      mainDebt_pos   := wf.mainDebt_pos
      ltvSynth_zero  := wf.ltvSynth_zero }
  -- new synth = mainDebt * 1.005 / ltSynth ≥ 0
  simp only [maintainPeg, mintSynthToPeg]
  exact div_nonneg (mul_nonneg wf.mainDebt_pos.le (by norm_num)) wf.ltSynth_pos.le

/-- **Phase 1 ↔ Phase 2 bridge.** A full maintenance tick from a `WellFormed` state
lands at `mainHF ≥ 1`: interest accrual followed by the re-peg never breaks the
never-liquidated guarantee. -/
theorem tick_safe (s : State) (δ : ℝ)
    (wf : WellFormed s) (hδ : 0 ≤ δ) :
    1 ≤ (s.tick δ).mainHF := by
  apply floor_main_hf
  · -- WellFormed (tick δ): accrue raises mainDebt by δ ≥ 0, then re-peg keeps WF
    have wf' : WellFormed (s.accrueInterest δ) :=
      { coll_nonneg    := wf.coll_nonneg
        price_nonneg   := wf.price_nonneg
        ltColl_nonneg  := wf.ltColl_nonneg
        ltColl_le_one  := wf.ltColl_le_one
        ltSynth_pos    := wf.ltSynth_pos
        synth_nonneg   := wf.synth_nonneg
        mainDebt_pos   := by simp only [accrueInterest]; linarith [wf.mainDebt_pos]
        ltvSynth_zero  := wf.ltvSynth_zero }
    exact maintainPeg_wellFormed _ wf'
  · exact tick_preserves_floor s δ hδ wf.mainDebt_pos wf.ltSynth_pos

end State
end Propeller
