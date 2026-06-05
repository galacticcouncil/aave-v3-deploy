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

/-- On-chain integer state: WAD amounts, bps thresholds — what Solidity stores. -/
structure IState where
  synthWad    : ℕ
  ltSynthBps  : ℕ
  mainDebtWad : ℕ

/-- Synthetic risk-weighted value as Aave computes it: a **flooring** mul-div. -/
def IState.synthValueWad (s : IState) : ℕ := s.synthWad * s.ltSynthBps / Bps

/-- Integer `principalFloored`, exactly as the on-chain guard checks it. -/
def IState.principalFloored (s : IState) : Prop := s.mainDebtWad ≤ s.synthValueWad

/-- Embed the integer state into the real spec state, dividing out the scales.
Fields irrelevant to the floor take harmless defaults. -/
noncomputable def IState.toReal (s : IState) : Propeller.State where
  coll := 0
  price := 0
  ltColl := 0
  ltvColl := 0
  synth := (s.synthWad : ℝ) / Wad
  ltSynth := (s.ltSynthBps : ℝ) / Bps
  ltvSynth := 0
  mainDebt := (s.mainDebtWad : ℝ) / Wad
  primeAmt := 0
  primePrice := 0
  ltPrime := 0
  subDebt := 0
  shares := 0
  escrowShares := 0

end FixedPoint
end Propeller
