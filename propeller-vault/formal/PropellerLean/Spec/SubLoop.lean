import PropellerLean.Spec.Redemption

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

end State
end Propeller
