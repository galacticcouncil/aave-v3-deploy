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

/-! ### pegBand preservation

`pegBand s ε := mainDebt ≤ synth·ltSynth ≤ mainDebt·(1+ε)` — the synthetic tracks the Main debt
within the spec buffer. Its **lower** bound is exactly `principalFloored`; the **upper** bound caps
over-minting. The maintenance re-peg sets `synth·ltSynth = mainDebt·1.005`, so `tick`/`repay`
re-establish `pegBand … 0.005`; `deLever` touches neither `synth` nor `mainDebt`, so it preserves any
band. -/

/-- The maintenance re-peg lands the synthetic in the spec peg band (`ε = 0.005`). -/
theorem maintainPeg_pegBand (s : State) (hd : 0 ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    s.maintainPeg.pegBand 0.005 := by
  simp only [pegBand, maintainPeg, mintSynthToPeg]
  have hcancel : s.mainDebt * 1.005 / s.ltSynth * s.ltSynth = s.mainDebt * 1.005 :=
    div_mul_cancel₀ (s.mainDebt * 1.005) (ne_of_gt hlt)
  rw [hcancel]
  have h15 : (1 : ℝ) + 0.005 = 1.005 := by norm_num
  rw [h15]
  exact ⟨by nlinarith [hd], le_refl _⟩

/-- A full maintenance tick re-establishes the peg band. -/
theorem tick_pegBand (s : State) (δ : ℝ)
    (hδ : 0 ≤ δ) (hd : 0 < s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.tick δ).pegBand 0.005 := by
  unfold tick
  apply maintainPeg_pegBand
  · simp only [accrueInterest]; linarith
  · simpa [accrueInterest] using hlt

/-- A repay-then-repeg re-establishes the peg band (`r ≤ mainDebt` suffices for the band). -/
theorem repay_pegBand (s : State) (r : ℝ)
    (hr : r ≤ s.mainDebt) (hlt : 0 < s.ltSynth) :
    (s.repay r).pegBand 0.005 := by
  unfold repay
  apply maintainPeg_pegBand
  · simp only; linarith
  · simpa using hlt

/-- `deLever` preserves any peg band — it touches neither `synth`, `mainDebt`, nor `ltSynth`. -/
theorem deLever_pegBand (s : State) (a ε : ℝ) (h : s.pegBand ε) :
    (s.deLever a).pegBand ε := by
  simpa [pegBand, deLever] using h

/-! ### Capstone — the per-step safety bundle

`LoopSafe s t` bundles the invariants the loop maintains at every step: the state is `WellFormed`, the
synthetic sits in the spec peg band (`pegBand … 0.005`, whose lower bound *is* `principalFloored`),
and the sub-loop sits at/above the de-lever trigger. Each transition (`tick`/`repay`/`deLever`)
preserves it, composing the proofs above — and because `WellFormed` is in the bundle, `LoopSafe`
directly implies the never-liquidated guarantee `mainHF ≥ 1` (`LoopSafe_mainHF`). (Note: `freedBacked`
is deliberately *not* in `LoopSafe` — interest accrual raises `mainDebt` while loop equity is fixed, so
it erodes between harvests; it is the redemption-time precondition for `collateral_out_ge_in`, proven
separately.) -/

/-- The per-step safety bundle: `WellFormed`, synthetic in the peg band, loop at/above the trigger. -/
def LoopSafe (s : State) (t : ℝ) : Prop :=
  WellFormed s ∧ s.pegBand 0.005 ∧ s.subLoopHealthy t

/-- `principalFloored` is the lower edge of the bundled peg band. -/
theorem LoopSafe_principalFloored (s : State) (t : ℝ) (h : s.LoopSafe t) : s.principalFloored :=
  h.2.1.1

/-- **synthConserved** (over-mint cap) is the upper edge of the bundled peg band: the synthetic's
risk-weighted value never exceeds the Main debt by more than the spec buffer (`synth·ltSynth ≤
mainDebt·1.005`). So the bundle covers both directions of §8 `synthConserved`. -/
theorem LoopSafe_synthConserved (s : State) (t : ℝ) (h : s.LoopSafe t) :
    s.synth * s.ltSynth ≤ s.mainDebt * (1 + 0.005) :=
  h.2.1.2

/-- **noSynthBorrow** follows from the bundle: the `WellFormed` conjunct carries `ltvSynth = 0`, so
borrow capacity is exactly the real collateral's — the synthetic unlocks no borrowing. -/
theorem LoopSafe_noSynthBorrow (s : State) (t : ℝ) (h : s.LoopSafe t) :
    s.borrowCapacity = s.coll * s.price * s.ltvColl :=
  synth_adds_no_borrow_power s h.1

/-- The bundle implies the headline never-liquidated guarantee. -/
theorem LoopSafe_mainHF (s : State) (t : ℝ) (h : s.LoopSafe t) : 1 ≤ s.mainHF :=
  floor_main_hf s h.1 h.2.1.1

/-- A full maintenance tick preserves the safety bundle (positivity of `mainDebt`/`ltSynth` comes
from the `WellFormed` conjunct, so no extra hypotheses beyond `δ ≥ 0`). -/
theorem tick_LoopSafe (s : State) (δ t : ℝ) (hδ : 0 ≤ δ) (h : s.LoopSafe t) :
    (s.tick δ).LoopSafe t :=
  ⟨tick_wellFormed s δ h.1 hδ,
   tick_pegBand s δ hδ h.1.mainDebt_pos h.1.ltSynth_pos,
   tick_subLoopHealthy s δ t h.2.2⟩

/-- A partial repay-then-repeg (`r < mainDebt`) preserves the safety bundle. -/
theorem repay_LoopSafe (s : State) (r t : ℝ)
    (hr : r < s.mainDebt) (h : s.LoopSafe t) :
    (s.repay r).LoopSafe t :=
  ⟨repay_wellFormed s r h.1 hr,
   repay_pegBand s r (le_of_lt hr) h.1.ltSynth_pos,
   repay_subLoopHealthy s r t h.2.2⟩

/-- A de-lever step on a solvent loop preserves the safety bundle (WellFormed + peg band invariant,
trigger raised). -/
theorem deLever_LoopSafe (s : State) (a t : ℝ)
    (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (hδpos : 0 < a * s.primePrice) (hδlt : a * s.primePrice < s.subDebt)
    (hsolvent : s.subDebt ≤ s.primeAmt * s.primePrice) (h : s.LoopSafe t) :
    (s.deLever a).LoopSafe t :=
  ⟨deLever_wellFormed s a h.1,
   deLever_pegBand s a 0.005 h.2.1,
   deLever_subLoopHealthy s a t hlt hD hδpos hδlt hsolvent h.2.2⟩

/-! ### Cross-preservation: redemption ↔ loop

The redemption ops (`requestRedeem`/`claimShares`) touch only `shares`/`escrowShares`, so they leave
every `LoopSafe` field fixed; the maintenance/unwind ops touch only Main/loop fields, so they leave
`escrowOk` fixed. These trivial-invariance lemmas let the two safety properties travel together. -/

theorem deLever_escrowOk (s : State) (a : ℝ) (h : s.escrowOk) : (s.deLever a).escrowOk := by
  simpa [escrowOk, deLever] using h

theorem tick_escrowOk (s : State) (δ : ℝ) (h : s.escrowOk) : (s.tick δ).escrowOk := by
  simpa [escrowOk, tick, maintainPeg, mintSynthToPeg, accrueInterest] using h

theorem repay_escrowOk (s : State) (r : ℝ) (h : s.escrowOk) : (s.repay r).escrowOk := by
  simpa [escrowOk, repay, maintainPeg, mintSynthToPeg] using h

theorem requestRedeem_wellFormed (s : State) (x : ℝ) (wf : WellFormed s) :
    WellFormed (s.requestRedeem x) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

theorem claimShares_wellFormed (s : State) (x : ℝ) (wf : WellFormed s) :
    WellFormed (s.claimShares x) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

/-- Requesting a redemption (escrowing shares) preserves the loop safety bundle. -/
theorem requestRedeem_LoopSafe (s : State) (t x : ℝ) (h : s.LoopSafe t) :
    (s.requestRedeem x).LoopSafe t := by
  obtain ⟨wf, pb, sh⟩ := h
  refine ⟨requestRedeem_wellFormed s x wf, ?_, ?_⟩
  · simpa [pegBand, requestRedeem] using pb
  · simpa [subLoopHealthy, subHF, requestRedeem] using sh

/-- Claiming (burning escrowed shares) preserves the loop safety bundle. -/
theorem claimShares_LoopSafe (s : State) (t x : ℝ) (h : s.LoopSafe t) :
    (s.claimShares x).LoopSafe t := by
  obtain ⟨wf, pb, sh⟩ := h
  refine ⟨claimShares_wellFormed s x wf, ?_, ?_⟩
  · simpa [pegBand, claimShares] using pb
  · simpa [subLoopHealthy, subHF, claimShares] using sh

/-- **Full safety bundle:** loop safety *and* escrow well-formedness — all six §8 invariants in one
predicate (`WellFormed`, `pegBand` [floor + over-mint cap], `subLoopHealthy` via `LoopSafe`; plus
`escrowOk` [escrow] and `0 ≤ shares` [shareConservation]). -/
def Safe (s : State) (t : ℝ) : Prop := s.LoopSafe t ∧ s.escrowOk

/-- **Genesis is `Safe`.** Every deposit ends by pegging the synthetic (`maintainPeg`). From a
well-formed base position with a healthy sub-loop and clean escrow, that peg step lands in a `Safe`
state: the re-peg establishes `pegBand` and keeps `WellFormed`, while the loop fields and escrow are
untouched. This is the seed `run_Safe` carries forward through every subsequent operation. -/
theorem maintainPeg_Safe (s : State) (t : ℝ)
    (wf : WellFormed s) (hhealthy : s.subLoopHealthy t) (hesc : s.escrowOk) :
    s.maintainPeg.Safe t := by
  refine ⟨⟨maintainPeg_wellFormed s wf,
           maintainPeg_pegBand s wf.mainDebt_pos.le wf.ltSynth_pos, ?_⟩, ?_⟩
  · unfold subLoopHealthy at *; rwa [maintainPeg_subHF]
  · simpa [escrowOk, maintainPeg, mintSynthToPeg] using hesc

/-! ### `freedBacked` preservation

`freedBacked s := mainDebt ≤ loopEquity` — the loop's value-stable equity covers the Main HOLLAR debt
(the redemption-time precondition for `collateral_out_ge_in`). Unlike the other invariants it is *not*
unconditionally preserved: `tick` accrues interest (raises `mainDebt`) while loop equity is fixed, so it
holds only while the accrued debt stays covered (`mainDebt + δ ≤ loopEquity` — the keeper's backing
obligation). `repay` with `0 ≤ r` only lowers the debt, so it helps; `deLever` keeps equity invariant
(`deLever_freedBacked`); the redemption ops touch neither side. -/

theorem tick_freedBacked (s : State) (δ : ℝ) (hbk : s.mainDebt + δ ≤ s.loopEquity) :
    (s.tick δ).freedBacked := by
  unfold freedBacked
  have hd : (s.tick δ).mainDebt = s.mainDebt + δ := by
    simp [tick, maintainPeg, mintSynthToPeg, accrueInterest]
  have he : (s.tick δ).loopEquity = s.loopEquity := by
    simp [loopEquity, tick, maintainPeg, mintSynthToPeg, accrueInterest]
  rw [hd, he]; exact hbk

theorem repay_freedBacked (s : State) (r : ℝ) (hr0 : 0 ≤ r) (h : s.freedBacked) :
    (s.repay r).freedBacked := by
  unfold freedBacked at *
  have hd : (s.repay r).mainDebt = s.mainDebt - r := by
    simp [repay, maintainPeg, mintSynthToPeg]
  have he : (s.repay r).loopEquity = s.loopEquity := by
    simp [loopEquity, repay, maintainPeg, mintSynthToPeg]
  rw [hd, he]; linarith

theorem requestRedeem_freedBacked (s : State) (x : ℝ) (h : s.freedBacked) :
    (s.requestRedeem x).freedBacked := by
  simpa [freedBacked, loopEquity, requestRedeem] using h

theorem claimShares_freedBacked (s : State) (x : ℝ) (h : s.freedBacked) :
    (s.claimShares x).freedBacked := by
  simpa [freedBacked, loopEquity, claimShares] using h

theorem maintainPeg_freedBacked (s : State) (h : s.freedBacked) : s.maintainPeg.freedBacked := by
  unfold freedBacked at *
  have hd : s.maintainPeg.mainDebt = s.mainDebt := by simp [maintainPeg, mintSynthToPeg]
  have he : s.maintainPeg.loopEquity = s.loopEquity := by
    simp [loopEquity, maintainPeg, mintSynthToPeg]
  rw [hd, he]; exact h

/-- The full safety bundle **plus** the redemption-backing invariant `freedBacked`. -/
def SafeBacked (s : State) (t : ℝ) : Prop := s.Safe t ∧ s.freedBacked

/-- Genesis with backing: a freshly-pegged position that is additionally `freedBacked` is
`SafeBacked` (the peg step preserves the backing). -/
theorem maintainPeg_SafeBacked (s : State) (t : ℝ)
    (wf : WellFormed s) (hhealthy : s.subLoopHealthy t) (hesc : s.escrowOk) (hbk : s.freedBacked) :
    s.maintainPeg.SafeBacked t :=
  ⟨maintainPeg_Safe s t wf hhealthy hesc, maintainPeg_freedBacked s hbk⟩

/-! ### Loop yield — `freedBacked` is restored by carry

The loop runs a positive carry (aPRIME yield − HOLLAR borrow rate), crediting earned aPRIME to the
position. `accrueLoop g` adds `g ≥ 0` aPRIME — the economic dual of `deLever`. It touches no Main field
and no escrow, so it preserves `WellFormed`/`pegBand`/`escrowOk`; it *raises* `subHF` (more collateral,
same debt); and it raises `loopEquity` by `g·primePrice`, so it preserves `freedBacked` and — given
enough cumulative yield — **restores** it after interest accrual has eroded it. This is what makes the
`validBacked` backing precondition sustainable: the keeper harvests carry to keep the loop covering the
debt. -/

/-- Credit `g` earned aPRIME to the loop (positive-carry yield). -/
noncomputable def accrueLoop (s : State) (g : ℝ) : State :=
  { s with primeAmt := s.primeAmt + g }

/-- Yield raises loop equity by exactly `g·primePrice`. -/
theorem accrueLoop_loopEquity (s : State) (g : ℝ) :
    (s.accrueLoop g).loopEquity = s.loopEquity + g * s.primePrice := by
  simp only [loopEquity, accrueLoop]; ring

theorem accrueLoop_wellFormed (s : State) (g : ℝ) (wf : WellFormed s) :
    WellFormed (s.accrueLoop g) :=
  { coll_nonneg   := wf.coll_nonneg,   price_nonneg  := wf.price_nonneg
    ltColl_nonneg := wf.ltColl_nonneg, ltColl_le_one := wf.ltColl_le_one
    ltSynth_pos   := wf.ltSynth_pos,   synth_nonneg  := wf.synth_nonneg
    mainDebt_pos  := wf.mainDebt_pos,  ltvSynth_zero := wf.ltvSynth_zero }

theorem accrueLoop_pegBand (s : State) (g ε : ℝ) (h : s.pegBand ε) : (s.accrueLoop g).pegBand ε := by
  simpa [pegBand, accrueLoop] using h

theorem accrueLoop_escrowOk (s : State) (g : ℝ) (h : s.escrowOk) : (s.accrueLoop g).escrowOk := by
  simpa [escrowOk, accrueLoop] using h

/-- Yield raises the sub-loop health factor (more collateral against the same debt). -/
theorem accrueLoop_raises_subHF (s : State) (g : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt) :
    s.subHF ≤ (s.accrueLoop g).subHF := by
  simp only [subHF, accrueLoop]
  gcongr
  nlinarith [mul_nonneg (mul_nonneg hg hp) hlt]

/-- Yield keeps the loop at/above the trigger (it only raises `subHF`). -/
theorem accrueLoop_subLoopHealthy (s : State) (g t : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (h : s.subLoopHealthy t) : (s.accrueLoop g).subLoopHealthy t := by
  unfold subLoopHealthy at *
  exact le_trans h (accrueLoop_raises_subHF s g hg hp hlt hD)

/-- Yield preserves the loop safety bundle. -/
theorem accrueLoop_LoopSafe (s : State) (g t : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (hlt : 0 ≤ s.ltPrime) (hD : 0 < s.subDebt)
    (h : s.LoopSafe t) : (s.accrueLoop g).LoopSafe t :=
  ⟨accrueLoop_wellFormed s g h.1,
   accrueLoop_pegBand s g 0.005 h.2.1,
   accrueLoop_subLoopHealthy s g t hg hp hlt hD h.2.2⟩

/-- Yield preserves `freedBacked` (it only grows the loop equity backing the debt). -/
theorem accrueLoop_freedBacked (s : State) (g : ℝ)
    (hg : 0 ≤ g) (hp : 0 ≤ s.primePrice) (h : s.freedBacked) : (s.accrueLoop g).freedBacked := by
  unfold freedBacked at *
  rw [accrueLoop_loopEquity]
  simp only [accrueLoop]
  nlinarith [h, mul_nonneg hg hp]

/-- **`freedBacked` restored by yield.** Even from a state whose backing was eroded (by interest
accrual), once cumulative yield brings the loop equity back up to the Main debt
(`mainDebt ≤ loopEquity + g·primePrice`), the position is `freedBacked` again. -/
theorem accrueLoop_restores_freedBacked (s : State) (g : ℝ)
    (hcover : s.mainDebt ≤ s.loopEquity + g * s.primePrice) :
    (s.accrueLoop g).freedBacked := by
  unfold freedBacked
  rw [accrueLoop_loopEquity]
  simpa only [accrueLoop] using hcover

end State

/-! ### Reachability — `LoopSafe` is closed under any valid operation sequence

Single-step preservation is not the whole story: we want *every reachable state* safe. Model the
protocol's state-changing actions as an `Op`, with a per-op `valid` precondition (the side-conditions
each transition needs *at the current state*), and `run` them in sequence. `run_LoopSafe` then proves:
from any `LoopSafe` start, executing **any** valid trace lands in a `LoopSafe` state — so with
`LoopSafe_mainHF`, every reachable state is never-liquidated. -/

/-- The state-changing protocol actions in the ℝ-spec — the maintenance/unwind ops plus the two
redemption ops, i.e. the full §6 entrypoint surface. -/
inductive Op
  | tick (δ : ℝ)
  | repay (r : ℝ)
  | deLever (a : ℝ)
  | requestRedeem (x : ℝ)
  | claim (x : ℝ)
  | accrueLoop (g : ℝ)

/-- Apply one operation. -/
noncomputable def Op.apply (s : State) : Op → State
  | .tick δ         => s.tick δ
  | .repay r        => s.repay r
  | .deLever a      => s.deLever a
  | .requestRedeem x => s.requestRedeem x
  | .claim x        => s.claimShares x
  | .accrueLoop g   => s.accrueLoop g

/-- The precondition for an operation to be a legitimate transition *at `s`* (mirrors the on-chain
guards): non-negative interest accrual; strictly-partial repay; a positive value-stable de-lever
slice on a solvent loop; a redemption request within free shares; a claim within escrowed shares. -/
def Op.valid (s : State) : Op → Prop
  | .tick δ   => 0 ≤ δ
  | .repay r  => r < s.mainDebt
  | .deLever a =>
      0 ≤ s.ltPrime ∧ 0 < s.subDebt ∧ 0 < a * s.primePrice ∧
        a * s.primePrice < s.subDebt ∧ s.subDebt ≤ s.primeAmt * s.primePrice
  | .requestRedeem x => 0 ≤ x ∧ s.escrowShares + x ≤ s.shares
  | .claim x => x ≤ s.escrowShares
  | .accrueLoop g => 0 ≤ g ∧ 0 ≤ s.primePrice ∧ 0 ≤ s.ltPrime ∧ 0 < s.subDebt

/-- One valid operation preserves the loop safety bundle (redemption ops preserve it unconditionally,
since they touch no `LoopSafe` field). -/
theorem Op.apply_LoopSafe (s : State) (t : ℝ) (op : Op)
    (hv : op.valid s) (h : s.LoopSafe t) : (op.apply s).LoopSafe t := by
  cases op with
  | tick δ => exact State.tick_LoopSafe s δ t hv h
  | repay r => exact State.repay_LoopSafe s r t hv h
  | deLever a =>
      obtain ⟨h1, h2, h3, h4, h5⟩ := hv
      exact State.deLever_LoopSafe s a t h1 h2 h3 h4 h5 h
  | requestRedeem x => exact State.requestRedeem_LoopSafe s t x h
  | claim x => exact State.claimShares_LoopSafe s t x h
  | accrueLoop g =>
      obtain ⟨hg, hp, hlt, hD⟩ := hv
      exact State.accrueLoop_LoopSafe s g t hg hp hlt hD h

/-- One valid operation preserves `escrowOk` (maintenance/unwind ops touch no escrow field; the
redemption ops carry their own escrow-preservation guards). -/
theorem Op.apply_escrowOk (s : State) (op : Op)
    (hv : op.valid s) (h : s.escrowOk) : (op.apply s).escrowOk := by
  cases op with
  | tick δ => exact State.tick_escrowOk s δ h
  | repay r => exact State.repay_escrowOk s r h
  | deLever a => exact State.deLever_escrowOk s a h
  | requestRedeem x =>
      obtain ⟨hx, hcap⟩ := hv
      exact State.requestRedeem_escrowOk s x hx hcap h
  | claim x => exact State.claimShares_escrowOk s x hv h
  | accrueLoop g => exact State.accrueLoop_escrowOk s g h

/-- One valid operation preserves the **full** safety bundle. -/
theorem Op.apply_Safe (s : State) (t : ℝ) (op : Op)
    (hv : op.valid s) (h : s.Safe t) : (op.apply s).Safe t :=
  ⟨Op.apply_LoopSafe s t op hv h.1, Op.apply_escrowOk s op hv h.2⟩

/-- Run a sequence of operations in order. -/
noncomputable def run (s : State) : List Op → State
  | [] => s
  | op :: ops => run (op.apply s) ops

/-- A trace is valid when each op satisfies its precondition *at the state it executes on*. -/
def runValid (s : State) : List Op → Prop
  | [] => True
  | op :: ops => op.valid s ∧ runValid (op.apply s) ops

/-- **Reachability / transition-system safety.** From any `LoopSafe` state, executing any valid
operation trace lands in a `LoopSafe` state. -/
theorem run_LoopSafe (s : State) (t : ℝ) (ops : List Op)
    (hv : runValid s ops) (h : s.LoopSafe t) : (run s ops).LoopSafe t := by
  induction ops generalizing s with
  | nil => exact h
  | cons op ops ih => exact ih (op.apply s) hv.2 (Op.apply_LoopSafe s t op hv.1 h)

/-- **Whole-protocol safety.** From any `Safe` state, executing any valid trace over the full action
set (maintenance, unwind, **and** redemption) lands in a `Safe` state — all six §8 invariants hold at
every reachable state. -/
theorem run_Safe (s : State) (t : ℝ) (ops : List Op)
    (hv : runValid s ops) (h : s.Safe t) : (run s ops).Safe t := by
  induction ops generalizing s with
  | nil => exact h
  | cons op ops ih => exact ih (op.apply s) hv.2 (Op.apply_Safe s t op hv.1 h)

/-- Every reachable state is never liquidated: `mainHF ≥ 1` after any valid trace. -/
theorem run_mainHF (s : State) (t : ℝ) (ops : List Op)
    (hv : runValid s ops) (h : s.Safe t) : 1 ≤ (run s ops).mainHF :=
  State.LoopSafe_mainHF _ t (run_Safe s t ops hv h).1

/-- **End-to-end safety from genesis.** Starting from a freshly-deposited (pegged) position — a
well-formed base with a healthy loop and clean escrow — *any* valid sequence of protocol operations
leaves the position never liquidated (`mainHF ≥ 1`). Genesis `Safe` (`maintainPeg_Safe`) seeds the
reachability closure (`run_Safe`); no extra hypotheses about reachable states are needed. -/
theorem genesis_run_mainHF (s : State) (t : ℝ) (ops : List Op)
    (wf : WellFormed s) (hhealthy : s.subLoopHealthy t) (hesc : s.escrowOk)
    (hv : runValid s.maintainPeg ops) :
    1 ≤ (run s.maintainPeg ops).mainHF :=
  run_mainHF s.maintainPeg t ops hv (State.maintainPeg_Safe s t wf hhealthy hesc)

/-! ### Threading `freedBacked` through the transition system

`freedBacked` needs a stronger per-op precondition than `Safe` (only `tick` can break it). `validBacked`
strengthens `valid`: `tick` must keep the accrued debt backed (`mainDebt + δ ≤ loopEquity`), and `repay`
must be non-negative; all other ops are unchanged. Every `validBacked` trace is a `valid` trace, so
`SafeBacked := Safe ∧ freedBacked` is closed under `validBacked` traces — and at every such reachable
state the redemption solvency `collateral_out_ge_in` holds. -/

/-- The backing-aware precondition: as `valid`, but `tick` must keep the debt covered and `repay` is
non-negative. -/
def Op.validBacked (s : State) : Op → Prop
  | .tick δ   => 0 ≤ δ ∧ s.mainDebt + δ ≤ s.loopEquity
  | .repay r  => 0 ≤ r ∧ r < s.mainDebt
  | .deLever a =>
      0 ≤ s.ltPrime ∧ 0 < s.subDebt ∧ 0 < a * s.primePrice ∧
        a * s.primePrice < s.subDebt ∧ s.subDebt ≤ s.primeAmt * s.primePrice
  | .requestRedeem x => 0 ≤ x ∧ s.escrowShares + x ≤ s.shares
  | .claim x => x ≤ s.escrowShares
  | .accrueLoop g => 0 ≤ g ∧ 0 ≤ s.primePrice ∧ 0 ≤ s.ltPrime ∧ 0 < s.subDebt

/-- A backing-valid op is in particular `valid`. -/
theorem Op.validBacked_valid (s : State) (op : Op) (h : op.validBacked s) : op.valid s := by
  cases op with
  | tick δ => exact h.1
  | repay r => exact h.2
  | deLever a => exact h
  | requestRedeem x => exact h
  | claim x => exact h
  | accrueLoop g => exact h

/-- One backing-valid op preserves `freedBacked`. -/
theorem Op.apply_freedBacked (s : State) (op : Op)
    (hv : op.validBacked s) (h : s.freedBacked) : (op.apply s).freedBacked := by
  cases op with
  | tick δ => exact State.tick_freedBacked s δ hv.2
  | repay r => exact State.repay_freedBacked s r hv.1 h
  | deLever a => exact State.deLever_freedBacked s a h
  | requestRedeem x => exact State.requestRedeem_freedBacked s x h
  | claim x => exact State.claimShares_freedBacked s x h
  | accrueLoop g =>
      obtain ⟨hg, hp, _, _⟩ := hv
      exact State.accrueLoop_freedBacked s g hg hp h

/-- One backing-valid op preserves the full `SafeBacked` bundle. -/
theorem Op.apply_SafeBacked (s : State) (t : ℝ) (op : Op)
    (hv : op.validBacked s) (h : s.SafeBacked t) : (op.apply s).SafeBacked t :=
  ⟨Op.apply_Safe s t op (Op.validBacked_valid s op hv) h.1,
   Op.apply_freedBacked s op hv h.2⟩

/-- A trace is backing-valid when each op meets its backing-aware precondition at its state. -/
def runValidBacked (s : State) : List Op → Prop
  | [] => True
  | op :: ops => op.validBacked s ∧ runValidBacked (op.apply s) ops

/-- **Whole-protocol safety with backing.** From any `SafeBacked` state, any backing-valid trace lands
in a `SafeBacked` state — all six §8 invariants *and* `freedBacked` hold at every reachable state. -/
theorem run_SafeBacked (s : State) (t : ℝ) (ops : List Op)
    (hv : runValidBacked s ops) (h : s.SafeBacked t) : (run s ops).SafeBacked t := by
  induction ops generalizing s with
  | nil => exact h
  | cons op ops ih => exact ih (op.apply s) hv.2 (Op.apply_SafeBacked s t op hv.1 h)

/-- **Redemption solvency everywhere.** At every state reachable by a backing-valid trace, a full
unwind returns at least the deposited collateral (`collateral_out_ge_in`) — the principal-back
guarantee holds throughout the protocol's life, not just at the seed. -/
theorem run_collateral_out_ge_in (s : State) (t : ℝ) (ops : List Op)
    (hv : runValidBacked s ops) (h : s.SafeBacked t) :
    (run s ops).coll ≤ (run s ops).collateralReturned :=
  State.collateral_out_ge_in _ (run_SafeBacked s t ops hv h).2

end Propeller
