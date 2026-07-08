import PropellerLean.Spec.Ops

/-!
# Propeller — redemption lifecycle & solvency (Phase 2, cont.)

The async withdrawal path (`requestRedeem → unwind → settle → claim`) and its
invariants:

* `escrowOk` — escrowed shares are non-negative and never exceed outstanding shares.
* `requestRedeem` / `claimShares` preserve `escrowOk` and keep `shares ≥ 0`
  (**escrow** + **shareConservation**).
* `freedBacked` — the loop's value-stable equity (`primeAmt·primePrice − subDebt`)
  covers the Main HOLLAR debt, so no collateral is sold to repay it.
* `collateral_out_ge_in` — under `freedBacked`, settlement returns the **full**
  collateral (out ≥ in): the depositor's principal comes back, repaid from the loop.
-/

namespace Propeller
namespace State

/-- **escrow** invariant: escrowed shares are a non-negative subset of all shares. -/
def escrowOk (s : State) : Prop := 0 ≤ s.escrowShares ∧ s.escrowShares ≤ s.shares

/-- Escrow `x` shares for a pending redemption. -/
def requestRedeem (s : State) (x : ℝ) : State :=
  { s with escrowShares := s.escrowShares + x }

/-- Burn `x` escrowed shares on claim. -/
def claimShares (s : State) (x : ℝ) : State :=
  { s with shares := s.shares - x, escrowShares := s.escrowShares - x }

/-- `requestRedeem` preserves `escrowOk` when there are enough free shares. -/
theorem requestRedeem_escrowOk (s : State) (x : ℝ)
    (hx : 0 ≤ x) (hcap : s.escrowShares + x ≤ s.shares) (h : escrowOk s) :
    escrowOk (s.requestRedeem x) := by
  simp only [escrowOk, requestRedeem] at *
  exact ⟨by linarith [h.1], hcap⟩

/-- `claimShares` preserves `escrowOk`. -/
theorem claimShares_escrowOk (s : State) (x : ℝ)
    (hxe : x ≤ s.escrowShares) (h : escrowOk s) :
    escrowOk (s.claimShares x) := by
  simp only [escrowOk, claimShares] at *
  exact ⟨by linarith [h.1], by linarith [h.2]⟩

/-- **shareConservation:** claiming never drives total shares negative
(`x ≤ escrow ≤ shares`). -/
theorem claimShares_sharesNonneg (s : State) (x : ℝ)
    (hxe : x ≤ s.escrowShares) (h : escrowOk s) :
    0 ≤ (s.claimShares x).shares := by
  simp only [claimShares]
  linarith [h.1, h.2]

/-- Loop equity after repaying loop debt: `primeAmt·primePrice − subDebt`. -/
def loopEquity (s : State) : ℝ := s.primeAmt * s.primePrice - s.subDebt

/-- **freedBacked:** the loop's (value-stable) equity covers the Main HOLLAR debt.
This is exactly the seed-equity identity (debt = equity) preserved as the loop runs. -/
def freedBacked (s : State) : Prop := s.mainDebt ≤ s.loopEquity

/-- Collateral that must be sold to cover any debt the freed loop equity can't:
`max(mainDebt − loopEquity, 0) / price`. -/
noncomputable def collSold (s : State) : ℝ :=
  max (s.mainDebt - s.loopEquity) 0 / s.price

/-- Collateral returned on a full unwind = deposited collateral minus what was sold. -/
noncomputable def collateralReturned (s : State) : ℝ := s.coll - s.collSold

/-- Under `freedBacked`, no collateral is sold — the loop repays the debt entirely. -/
theorem freedBacked_no_coll_sold (s : State) (h : freedBacked s) :
    s.collSold = 0 := by
  unfold collSold
  rw [max_eq_right (by unfold freedBacked at h; linarith)]
  simp

/-- **collateral_out_ge_in.** With the loop equity backing the debt, settlement
returns at least the deposited collateral — the principal is made whole from the
value-stable loop, never by selling the collateral. -/
theorem collateral_out_ge_in (s : State) (h : freedBacked s) :
    s.coll ≤ s.collateralReturned := by
  unfold collateralReturned
  rw [freedBacked_no_coll_sold s h]
  linarith

end State
end Propeller
