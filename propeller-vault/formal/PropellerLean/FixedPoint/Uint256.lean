import PropellerLean.Spec.Invariants

/-!
# Propeller — on-chain fixed-point model (Phase 3)

The deployable layer is integer arithmetic: amounts in WAD (1e18), Aave liquidation
thresholds in basis points (1e4), and `mulDiv` that **floors**. This file models that
integer state; `Refine.lean` proves it refines the real spec.
-/

namespace Propeller
namespace FixedPoint

/-- Basis points — Aave's LT / LTV scale. -/
def Bps : ℕ := 10000
/-- WAD fixed-point scale (1e18). -/
def Wad : ℕ := 10 ^ 18

/-- On-chain integer state: WAD amounts, bps thresholds — what Solidity stores. The loop fields
(`primeAmtWad`/`primePriceWad`/`subDebtWad`) carry the PRIME-loop position. -/
structure IState where
  synthWad      : ℕ
  ltSynthBps    : ℕ
  mainDebtWad   : ℕ
  primeAmtWad   : ℕ := 0
  primePriceWad : ℕ := 0
  subDebtWad    : ℕ := 0
  ltPrimeBps    : ℕ := 0

/-- Synthetic risk-weighted value as Aave computes it: a **flooring** mul-div. -/
def IState.synthValueWad (s : IState) : ℕ := s.synthWad * s.ltSynthBps / Bps

/-- Integer `principalFloored`, exactly as the on-chain guard checks it. -/
def IState.principalFloored (s : IState) : Prop := s.mainDebtWad ≤ s.synthValueWad

/-- Loop collateral value as the chain computes it: `primeAmt·primePrice` via a **flooring** WAD
mul-div (`a·b/Wad`). The floor *underestimates* the collateral. -/
def IState.loopCollWad (s : IState) : ℕ := s.primeAmtWad * s.primePriceWad / Wad

/-- Integer `freedBacked`, as the on-chain guard checks it: floored loop collateral covers the Main
debt plus the loop debt (`mainDebt ≤ loopColl − subDebt ⟺ mainDebt + subDebt ≤ loopColl`). -/
def IState.freedBacked (s : IState) : Prop := s.mainDebtWad + s.subDebtWad ≤ s.loopCollWad

/-- Integer sub-loop health, as the on-chain liquidation guard checks it in **cleared** form (no
division): the loop sits at/above the trigger `tBps` (bps) when `t·subDebt ≤ subHF·subDebt`, i.e.
`tBps·subDebtWad ≤ loopColl·ltPrimeBps` (the floored loop collateral, risk-weighted by `ltPrimeBps`). -/
def IState.subLoopHealthy (s : IState) (tBps : ℕ) : Prop :=
  tBps * s.subDebtWad ≤ s.loopCollWad * s.ltPrimeBps

/-- On-chain loop yield: credit `gWad` earned aPRIME to the loop. -/
def IState.accrueLoop (s : IState) (gWad : ℕ) : IState :=
  { s with primeAmtWad := s.primeAmtWad + gWad }

/-- On-chain re-peg: mint the synthetic to the buffered target via a **flooring** mul-div,
`synth := mainDebt · kBps / ltSynthBps`, where `kBps` is the mint buffer in bps
(the spec's `1.005` ⇒ `kBps = 10050`). The mint floors *down*, and the floor guard
(`synthValueWad`) floors *again* — so soundness is the double-flooring question. -/
def IState.repegSynth (s : IState) (kBps : ℕ) : IState :=
  { s with synthWad := s.mainDebtWad * kBps / s.ltSynthBps }

/-- Embed the integer state into the real spec state, dividing out the scales.
Fields irrelevant to the modelled guards take harmless defaults. -/
noncomputable def IState.toReal (s : IState) : Propeller.State where
  coll := 0
  price := 0
  ltColl := 0
  ltvColl := 0
  synth := (s.synthWad : ℝ) / Wad
  ltSynth := (s.ltSynthBps : ℝ) / Bps
  ltvSynth := 0
  mainDebt := (s.mainDebtWad : ℝ) / Wad
  primeAmt := (s.primeAmtWad : ℝ) / Wad
  primePrice := (s.primePriceWad : ℝ) / Wad
  ltPrime := (s.ltPrimeBps : ℝ) / Bps
  subDebt := (s.subDebtWad : ℝ) / Wad
  shares := 0
  escrowShares := 0

end FixedPoint
end Propeller
