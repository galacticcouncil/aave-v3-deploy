import PropellerLean.Spec.Floor
import PropellerLean.FixedPoint.Refine

/-!
# Propeller — worked examples (spec-fidelity cross-check)

Concrete instantiations of the headline theorems on realistic Propeller parameters, so the abstract
claims can be read against real numbers (and so the hypotheses are demonstrably *satisfiable*, not
vacuous). Mirrors the plan's "confirm the Lean theorems' hypotheses match the tested states".

The example position: 1 ETH collateral at 2000 HOLLAR, Aave `ltColl = 0.80`, borrowed near max LTV
to `mainDebt = 980`; the synthetic reserve has `ltSynth = 0.98` and is minted to `synth = 1005`, so
`synth·ltSynth = 1005·0.98 = 984.9 = 980·1.005` — the spec's `1.005` buffer exactly.
-/

namespace Propeller
namespace Examples

open Propeller.State Propeller.FixedPoint

/-- A concrete, realistic Propeller Main position (loop fields irrelevant to the floor set to 0). -/
noncomputable def ethPosition : State where
  coll := 1
  price := 2000
  ltColl := 0.8
  ltvColl := 0.75
  synth := 1005
  ltSynth := 0.98
  ltvSynth := 0
  mainDebt := 980
  primeAmt := 0
  primePrice := 0
  ltPrime := 0
  subDebt := 0
  shares := 0
  escrowShares := 0

theorem ethPosition_wf : WellFormed ethPosition where
  coll_nonneg := by norm_num [ethPosition]
  price_nonneg := by norm_num [ethPosition]
  ltColl_nonneg := by norm_num [ethPosition]
  ltColl_le_one := by norm_num [ethPosition]
  ltSynth_pos := by norm_num [ethPosition]
  synth_nonneg := by norm_num [ethPosition]
  mainDebt_pos := by norm_num [ethPosition]
  ltvSynth_zero := by norm_num [ethPosition]

theorem ethPosition_floored : ethPosition.principalFloored :=
  peg_floored ethPosition 1.005 (by norm_num)
    (by norm_num [ethPosition]) (by norm_num [ethPosition])

/-- The headline, concretely: this position has `mainHF ≥ 1`. -/
theorem ethPosition_safe : 1 ≤ ethPosition.mainHF :=
  floor_main_hf ethPosition ethPosition_wf ethPosition_floored

/-- And it stays safe at a **total collateral wipeout** (`price = 0`): a bare max-LTV borrow would be
deep underwater here, but the synthetic floor keeps `mainHF ≥ 1`. -/
theorem ethPosition_safe_at_zero_price :
    1 ≤ ({ethPosition with price := 0} : State).mainHF :=
  never_liquidated_at_any_price ethPosition ethPosition_wf ethPosition_floored 0 (by norm_num)

/-! ### Integer re-peg: the dust threshold is real

With spec params (`kBps = 10050`, `Bps = 10000`, `ltSynthBps = 9800`), the re-peg soundness condition
is `9800 ≤ 50·mainDebtWad + 1`, i.e. `mainDebtWad ≥ 196` wei. A real position (`1` token of debt =
`10^18` wei) clears it by 16 orders of magnitude; the boundary sits at 196 vs 195 wei. -/

/-- A realistic integer position with 1 token of Main debt. -/
def dustyPosition : IState where
  synthWad := 0
  ltSynthBps := 9800
  mainDebtWad := 10 ^ 18

/-- The on-chain re-peg satisfies the floor guard for a real position. -/
theorem dustyPosition_repeg_floored : (dustyPosition.repegSynth 10050).principalFloored :=
  repeg_principalFloored dustyPosition 10050
    (by norm_num [dustyPosition, Bps]) (by norm_num [Bps])
    (by norm_num [dustyPosition, Bps])

/-- The threshold is sharp: at exactly `196` wei of debt the soundness condition holds… -/
theorem dust_threshold_holds_at_196 :
    (9800 : ℕ) ≤ 196 * (10050 - Bps) + 1 := by norm_num [Bps]

/-- …and at `195` wei it fails — the genuine (economically irrelevant) dust edge below which the
double-flooring can undershoot the floor. -/
theorem dust_threshold_fails_at_195 :
    ¬ ((9800 : ℕ) ≤ 195 * (10050 - Bps) + 1) := by norm_num [Bps]

end Examples
end Propeller
