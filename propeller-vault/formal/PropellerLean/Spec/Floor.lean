import PropellerLean.Spec.Invariants

/-!
# Propeller — headline safety theorems (Phase 1)

The "never liquidated" guarantee, machine-checked:

* `floor_main_hf` — `principalFloored` ⟹ `mainHF ≥ 1`.
* `never_liquidated_at_any_price` — the floor holds at *every* collateral price
  `p ≥ 0`, including `p = 0` (collateral crash to zero).
* `peg_floored` — the spec's mint rule (`synth·LTsynth = mainDebt·k`, `k ≥ 1`)
  establishes `principalFloored`; `k = 1.005` is the spec's buffer.
* `synth_adds_no_borrow_power` / `borrow_indep_of_synth` — the synthetic (LTV 0)
  grants zero borrow capacity (`noSynthBorrow`, the no-money-printing guard).
-/

namespace Propeller
namespace State

/-- **Headline theorem.** If the synthetic floors the debt, the Main health factor
is at least 1 — so Aave never liquidates the principal. -/
theorem floor_main_hf (s : State) (wf : WellFormed s) (h : s.principalFloored) :
    1 ≤ s.mainHF := by
  have hD : 0 < s.mainDebt := wf.mainDebt_pos
  have hcoll : 0 ≤ s.coll * s.price * s.ltColl :=
    mul_nonneg (mul_nonneg wf.coll_nonneg wf.price_nonneg) wf.ltColl_nonneg
  have hN : s.mainDebt ≤ s.mainCollateralValue := by
    unfold mainCollateralValue
    have := h          -- principalFloored : mainDebt ≤ synth * ltSynth
    unfold principalFloored at this
    linarith
  unfold mainHF
  rw [le_div_iff₀ hD, one_mul]
  exact hN

/-- The crucial corollary: the floor is *price-independent*. For **any** collateral
price `p ≥ 0` — including `p = 0`, a total collateral wipeout — the Main position
still has `HF ≥ 1`. This is what a bare max-LTV borrow position can never achieve. -/
theorem never_liquidated_at_any_price
    (s : State) (wf : WellFormed s) (h : s.principalFloored) (p : ℝ) (hp : 0 ≤ p) :
    1 ≤ ({s with price := p} : State).mainHF := by
  apply floor_main_hf
  · exact
      { coll_nonneg    := wf.coll_nonneg
        price_nonneg   := hp
        ltColl_nonneg  := wf.ltColl_nonneg
        ltColl_le_one  := wf.ltColl_le_one
        ltSynth_pos    := wf.ltSynth_pos
        synth_nonneg   := wf.synth_nonneg
        mainDebt_pos   := wf.mainDebt_pos
        ltvSynth_zero  := wf.ltvSynth_zero }
  · -- principalFloored is unaffected by price
    simpa [principalFloored] using h

/-- The spec's mint rule establishes `principalFloored`. The protocol sets
`synth·LTsynth = mainDebt·k` with the buffer `k = 1.005 ≥ 1`. -/
theorem peg_floored (s : State) (k : ℝ) (hk : 1 ≤ k)
    (hpeg : s.synth * s.ltSynth = s.mainDebt * k) (hd : 0 ≤ s.mainDebt) :
    s.principalFloored := by
  unfold principalFloored
  rw [hpeg]
  nlinarith [hd, hk]

/-- **noSynthBorrow.** With the synthetic configured at LTV 0, borrow capacity is
exactly the real collateral's — the synthetic adds none. -/
theorem synth_adds_no_borrow_power (s : State) (wf : WellFormed s) :
    s.borrowCapacity = s.coll * s.price * s.ltvColl := by
  unfold borrowCapacity
  rw [wf.ltvSynth_zero]
  ring

/-- Stronger form: borrow capacity does not depend on the synthetic amount at all —
minting more synthetic can never unlock more borrowing (kills the circular-mint exploit). -/
theorem borrow_indep_of_synth (s : State) (wf : WellFormed s) (x : ℝ) :
    ({s with synth := x} : State).borrowCapacity = s.borrowCapacity := by
  unfold borrowCapacity
  rw [wf.ltvSynth_zero]
  ring

end State
end Propeller
