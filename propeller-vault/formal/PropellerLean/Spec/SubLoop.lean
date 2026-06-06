import PropellerLean.Spec.Redemption
import PropellerLean.Spec.Preservation

/-!
# Propeller — SubLoop de-lever / unwind step (ℝ-spec)

Models the loop's **de-lever** step: sell `a` aPRIME (at `primePrice`) and repay the proceeds
(`a·primePrice` HOLLAR) against the loop's own debt. PRIME is value-stable, so the step removes the
*same value* from collateral and debt — the deleveraging spiral that `pokeRepay` / `deLever` drive on
chain. Proven here:

* `deLever_loopEquity` — equity-neutral: `primeAmt·primePrice − subDebt` is invariant.
* `deLever_mainHF` / `deLever_principalFloored` — the Main leg is untouched, so `mainHF` and the
  principal floor are preserved (de-levering the loop can't endanger the principal).
* `deLever_raises_subHF` — when the loop is **solvent** (collateral value ≥ debt), unwinding a
  positive value-stable slice **raises** the sub-loop health factor — so de-lever always moves HF up
  toward target, the on-chain `deLever`/unwind-spiral safety property.
-/

namespace Propeller
namespace State

/-- De-lever by selling `a` aPRIME and repaying the (value-stable) proceeds against the loop debt. -/
noncomputable def deLever (s : State) (a : ℝ) : State :=
  { s with primeAmt := s.primeAmt - a, subDebt := s.subDebt - a * s.primePrice }

/-- **Equity-neutral.** The slice removes equal value from collateral and debt. -/
theorem deLever_loopEquity (s : State) (a : ℝ) :
    (s.deLever a).loopEquity = s.loopEquity := by
  simp only [loopEquity, deLever]; ring

/-- The Main position (collateral, synthetic, HOLLAR debt) is untouched, so its health factor is
unchanged — de-levering the loop never moves the principal's HF. -/
theorem deLever_mainHF (s : State) (a : ℝ) :
    (s.deLever a).mainHF = s.mainHF := by
  simp only [mainHF, mainCollateralValue, deLever]

/-- …and the principal floor is preserved. -/
theorem deLever_principalFloored (s : State) (a : ℝ) (h : s.principalFloored) :
    (s.deLever a).principalFloored := by
  simpa [principalFloored, deLever] using h

/-- **De-lever safety.** When the loop is solvent (`subDebt ≤ primeAmt·primePrice`, i.e.
`loopEquity ≥ 0`), unwinding a positive value-stable slice (`0 < a·primePrice < subDebt`) raises the
sub-loop health factor: `subHF s ≤ subHF (deLever s a)`. So de-lever monotonically moves HF up. -/
theorem deLever_raises_subHF (s : State) (a : ℝ)
    (hlt : 0 ≤ s.ltPrime)
    (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice)
    (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice) :
    s.subHF ≤ (s.deLever a).subHF := by
  have hDδ : 0 < s.subDebt - a * s.primePrice := by linarith
  simp only [subHF, deLever]
  rw [le_div_iff₀ hDδ, div_mul_eq_mul_div, div_le_iff₀ hD]
  nlinarith [mul_nonneg (mul_nonneg hlt hδpos.le) (sub_nonneg.mpr hsolvent)]

/-! ### De-lever and the redemption solvency guarantee

The headline user-facing theorem is `Redemption.collateral_out_ge_in`: under `freedBacked` (the loop's
value-stable equity covers the Main HOLLAR debt), a full unwind returns at least the deposited
collateral. Propeller unwinds *gradually* — a DCA sequence of `deLever` steps — so the guarantee is
only meaningful if it survives each step. It does: `deLever` leaves Main debt, collateral, and price
untouched and holds `loopEquity` invariant, so `freedBacked` and `collateralReturned` are preserved
unchanged by every step. The depositor stays made-whole throughout the unwind, not just at the end. -/

/-- **`freedBacked` is preserved by de-lever.** Main debt is untouched and `loopEquity` is invariant
(`deLever_loopEquity`), so the loop keeps backing the Main HOLLAR debt through each unwind step. -/
theorem deLever_freedBacked (s : State) (a : ℝ) (h : s.freedBacked) :
    (s.deLever a).freedBacked := by
  unfold freedBacked at *
  rw [deLever_loopEquity]
  exact h

/-- **Collateral returned is invariant under de-lever.** `collateralReturned = coll − collSold`, and
`collSold = max(mainDebt − loopEquity, 0)/price` depends only on quantities de-lever leaves fixed
(`coll`, `mainDebt`, `price`) plus the invariant `loopEquity`. -/
theorem deLever_collateralReturned (s : State) (a : ℝ) :
    (s.deLever a).collateralReturned = s.collateralReturned := by
  have he := deLever_loopEquity s a
  simp only [collateralReturned, collSold]
  rw [he]
  simp only [deLever]

/-- **De-lever preserves `collateral_out_ge_in`.** After any de-lever step on a `freedBacked` loop,
settlement still returns at least the deposited collateral — the gradual DCA unwind never erodes the
principal-back guarantee. -/
theorem deLever_collateral_out_ge_in (s : State) (a : ℝ) (h : s.freedBacked) :
    s.coll ≤ (s.deLever a).collateralReturned := by
  rw [deLever_collateralReturned]
  exact collateral_out_ge_in s h

/-! ### `subLoopHealthy` preservation

`subLoopHealthy s t := t ≤ s.subHF` (the loop stays at/above the de-lever trigger). The Main-position
maintenance ops (`accrueInterest`/`maintainPeg`/`tick`/`repay`) only touch `mainDebt`/`synth`, never
the loop fields `primeAmt·primePrice·ltPrime/subDebt`, so `subHF` is **invariant** under them and the
trigger is trivially held. The loop's own `deLever` step *raises* `subHF` on a solvent loop
(`deLever_raises_subHF`), so it preserves the trigger too. Hence every transition in the ℝ-spec keeps
the loop healthy. -/

theorem accrueInterest_subHF (s : State) (δ : ℝ) : (s.accrueInterest δ).subHF = s.subHF := by
  simp only [subHF, accrueInterest]

theorem maintainPeg_subHF (s : State) : s.maintainPeg.subHF = s.subHF := by
  simp only [subHF, maintainPeg, mintSynthToPeg]

theorem tick_subHF (s : State) (δ : ℝ) : (s.tick δ).subHF = s.subHF := by
  unfold tick
  rw [maintainPeg_subHF, accrueInterest_subHF]

theorem repay_subHF (s : State) (r : ℝ) : (s.repay r).subHF = s.subHF := by
  unfold repay
  rw [maintainPeg_subHF]
  simp only [subHF]

/-- The maintenance tick (accrue interest + re-peg) leaves the loop health untouched. -/
theorem tick_subLoopHealthy (s : State) (δ t : ℝ) (h : s.subLoopHealthy t) :
    (s.tick δ).subLoopHealthy t := by
  unfold subLoopHealthy at *; rwa [tick_subHF]

/-- Repaying Main debt + re-peg leaves the loop health untouched. -/
theorem repay_subLoopHealthy (s : State) (r t : ℝ) (h : s.subLoopHealthy t) :
    (s.repay r).subLoopHealthy t := by
  unfold subLoopHealthy at *; rwa [repay_subHF]

/-- **De-lever keeps the loop healthy.** On a solvent loop a de-lever step only raises `subHF`
(`deLever_raises_subHF`), so a state at/above the trigger stays at/above it. -/
theorem deLever_subLoopHealthy (s : State) (a t : ℝ)
    (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice) (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice)
    (h : s.subLoopHealthy t) :
    (s.deLever a).subLoopHealthy t := by
  unfold subLoopHealthy at *
  exact le_trans h (deLever_raises_subHF s a hlt hD hδpos hδlt hsolvent)

/-! ### Iterated (gradual) unwind

Propeller unwinds across many transactions — a *sequence* of `deLever` slices, not one big step.
`deLeverSeq s as` applies the per-step transition once per slice size in `as`. The per-step lemmas
lift to the whole sequence by induction: loop equity stays invariant, `freedBacked` is preserved, and
`collateralReturned` is unchanged — so **`collateral_out_ge_in` holds after an arbitrary finite
unwind**, making the "gradual DCA" guarantee explicit rather than only per-step. -/

/-- Apply `deLever` once per slice in `as`, in order. -/
noncomputable def deLeverSeq : State → List ℝ → State
  | s, [] => s
  | s, a :: as => deLeverSeq (s.deLever a) as

@[simp] theorem deLeverSeq_nil (s : State) : deLeverSeq s [] = s := rfl

theorem deLeverSeq_cons (s : State) (a : ℝ) (as : List ℝ) :
    deLeverSeq s (a :: as) = deLeverSeq (s.deLever a) as := rfl

/-- Loop equity is invariant under the whole unwind. -/
theorem deLeverSeq_loopEquity (s : State) (as : List ℝ) :
    (deLeverSeq s as).loopEquity = s.loopEquity := by
  induction as generalizing s with
  | nil => rfl
  | cons a as ih => rw [deLeverSeq_cons, ih (s.deLever a), deLever_loopEquity]

/-- `freedBacked` is preserved by the whole unwind. -/
theorem deLeverSeq_freedBacked (s : State) (as : List ℝ) (h : s.freedBacked) :
    (deLeverSeq s as).freedBacked := by
  induction as generalizing s with
  | nil => exact h
  | cons a as ih => exact ih (s.deLever a) (deLever_freedBacked s a h)

/-- Collateral returned is invariant under the whole unwind. -/
theorem deLeverSeq_collateralReturned (s : State) (as : List ℝ) :
    (deLeverSeq s as).collateralReturned = s.collateralReturned := by
  induction as generalizing s with
  | nil => rfl
  | cons a as ih => rw [deLeverSeq_cons, ih (s.deLever a), deLever_collateralReturned]

/-- **Iterated principal-back guarantee.** After *any* finite sequence of de-lever steps on a
`freedBacked` loop, settlement returns at least the originally deposited collateral — the gradual
DCA unwind keeps the depositor made whole at every point along the way. -/
theorem deLeverSeq_collateral_out_ge_in (s : State) (as : List ℝ) (h : s.freedBacked) :
    s.coll ≤ (deLeverSeq s as).collateralReturned := by
  rw [deLeverSeq_collateralReturned]
  exact collateral_out_ge_in s h

/-- `principalFloored` is preserved by the whole unwind: `deLever` touches no Main-position field, so
the floor is literally invariant under it (no solvency hypothesis needed). -/
theorem deLeverSeq_principalFloored (s : State) (as : List ℝ) (h : s.principalFloored) :
    (deLeverSeq s as).principalFloored := by
  induction as generalizing s with
  | nil => exact h
  | cons a as ih => exact ih (s.deLever a) (deLever_principalFloored s a h)

/-! ### WellFormed preservation

The three transitions keep the state `WellFormed`. `deLever` touches only loop fields, so it's
immediate; `tick`/`repay` end in a re-peg, so they reduce to `maintainPeg_wellFormed` once the
interim `mainDebt` is shown positive (`tick` raises it by `δ ≥ 0`; `repay` needs the **partial**
condition `r < mainDebt`, since a fully-repaid debt would violate `mainDebt_pos`). -/

/-- `deLever` preserves `WellFormed` — it changes only `primeAmt`/`subDebt`, no Main-position field. -/
theorem deLever_wellFormed (s : State) (a : ℝ) (wf : WellFormed s) : WellFormed (s.deLever a) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

/-- A full maintenance tick (accrue `δ ≥ 0`, then re-peg) preserves `WellFormed`. -/
theorem tick_wellFormed (s : State) (δ : ℝ) (wf : WellFormed s) (hδ : 0 ≤ δ) :
    WellFormed (s.tick δ) := by
  unfold tick
  apply maintainPeg_wellFormed
  exact
    { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
      ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
      ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
      mainDebt_pos  := by simp only [accrueInterest]; linarith [wf.mainDebt_pos]
      ltvSynth_zero := wf.ltvSynth_zero }

/-- A **partial** repay (`r < mainDebt`) then re-peg preserves `WellFormed`. -/
theorem repay_wellFormed (s : State) (r : ℝ) (wf : WellFormed s) (hr : r < s.mainDebt) :
    WellFormed (s.repay r) := by
  unfold repay
  apply maintainPeg_wellFormed
  exact
    { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
      ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
      ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
      mainDebt_pos  := by simp only; linarith
      ltvSynth_zero := wf.ltvSynth_zero }

/-! ### Capstone — the per-step safety bundle

`LoopSafe s t` bundles the invariants the loop maintains at every step: the state is `WellFormed`, the
principal is floored, and the sub-loop sits at/above the de-lever trigger. Each transition
(`tick`/`repay`/`deLever`) preserves it, composing the proofs above — and because `WellFormed` is
now in the bundle, `LoopSafe` directly implies the never-liquidated guarantee `mainHF ≥ 1`
(`LoopSafe_mainHF`). (Note: `freedBacked` is deliberately *not* in `LoopSafe` — interest accrual
raises `mainDebt` while loop equity is fixed, so it erodes between harvests; it is the redemption-time
precondition for `collateral_out_ge_in`, proven separately.) -/

/-- The per-step safety bundle: state `WellFormed`, principal floored, loop at/above the trigger. -/
def LoopSafe (s : State) (t : ℝ) : Prop :=
  WellFormed s ∧ s.principalFloored ∧ s.subLoopHealthy t

/-- The bundle implies the headline never-liquidated guarantee. -/
theorem LoopSafe_mainHF (s : State) (t : ℝ) (h : s.LoopSafe t) : 1 ≤ s.mainHF :=
  floor_main_hf s h.1 h.2.1

/-- A full maintenance tick preserves the safety bundle (positivity of `mainDebt`/`ltSynth` comes
from the `WellFormed` conjunct, so no extra hypotheses beyond `δ ≥ 0`). -/
theorem tick_LoopSafe (s : State) (δ t : ℝ) (hδ : 0 ≤ δ) (h : s.LoopSafe t) :
    (s.tick δ).LoopSafe t :=
  ⟨tick_wellFormed s δ h.1 hδ,
   tick_preserves_floor s δ hδ h.1.mainDebt_pos h.1.ltSynth_pos,
   tick_subLoopHealthy s δ t h.2.2⟩

/-- A partial repay-then-repeg (`r < mainDebt`) preserves the safety bundle. -/
theorem repay_LoopSafe (s : State) (r t : ℝ)
    (hr0 : 0 ≤ r) (hr : r < s.mainDebt) (h : s.LoopSafe t) :
    (s.repay r).LoopSafe t :=
  ⟨repay_wellFormed s r h.1 hr,
   repay_preserves_floor s r hr0 (le_of_lt hr) h.1.ltSynth_pos,
   repay_subLoopHealthy s r t h.2.2⟩

/-- A de-lever step on a solvent loop preserves the safety bundle (WellFormed + floor invariant,
trigger raised). -/
theorem deLever_LoopSafe (s : State) (a t : ℝ)
    (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice) (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice) (h : s.LoopSafe t) :
    (s.deLever a).LoopSafe t :=
  ⟨deLever_wellFormed s a h.1,
   deLever_principalFloored s a h.2.1,
   deLever_subLoopHealthy s a t hlt hD hδpos hδlt hsolvent h.2.2⟩

end State
end Propeller
