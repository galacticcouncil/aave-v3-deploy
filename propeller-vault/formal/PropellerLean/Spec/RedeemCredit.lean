import Mathlib

-- shared `variable` block carries `[DecidableEq Vault]` for the ops that use `Function.update`;
-- the pure credit lemmas don't. Intentional — silence the section-var lint.
set_option linter.unusedSectionVars false

/-!
# Propeller — shared-SubLoop redemption credit (`_creditFreed`): no over-credit

Models `SubLoop.sol`'s gradual-unwind credit book and proves the invariant the on-chain fix relies on:
a `_creditFreed(freed)` call distributes **at most `freed`**, so `reservedFreed` never exceeds the
HOLLAR the loop actually freed (⇒ pulls/claims can never revert on balance).

The book (mirroring the contract storage):
* `requested v` — `unwindRequested[v]`, per-vault equity targeted for unwind;
* `freed v`     — `freedHollar[v]`, credited-but-not-yet-pulled;
* `target`      — `unwindTargetEquity`, the outstanding equity still to free;
* `reservedFreed` — `Σ freed`, HOLLAR held back for vaults to pull.

`_creditFreed` distributes `freed` pro-rata by **`rem v = requested v − freed v`** (the FIX), capped at
`rem v`. The structural invariant `Σ rem = target` (`TargetMatched`) — preserved by `requestUnwind` /
`creditFreed` / `pull` — is exactly what bounds the distribution by `freed`.

Bonus: the **buggy** weighting (raw `requested`, which only shrinks on pull while `target` shrinks on
credit) is proven to over-credit by `(freed/target)·Σ freed` — bug G, formalized.
-/

namespace Propeller

open scoped BigOperators

/-- The shared-loop redemption credit book. -/
structure RedeemBook (Vault : Type*) where
  /-- the `_unwinders` registry: vaults with an open unwind request. -/
  holders       : Finset Vault
  /-- `unwindRequested[v]` — equity targeted for unwind. -/
  requested     : Vault → ℝ
  /-- `freedHollar[v]` — credited, not yet pulled. -/
  freed         : Vault → ℝ
  /-- `unwindTargetEquity` — outstanding equity still to free. -/
  target        : ℝ
  /-- `reservedFreed` — HOLLAR held back for pulls (= Σ freed). -/
  reservedFreed : ℝ

namespace RedeemBook

variable {Vault : Type*} [DecidableEq Vault]

/-- remaining-to-credit for a vault: `requested − freed` (the correct weighting basis). -/
def rem (B : RedeemBook Vault) (v : Vault) : ℝ := B.requested v - B.freed v

/-- **`TargetMatched`:** `Σ rem = target` — the invariant the fix relies on. -/
def TargetMatched (B : RedeemBook Vault) : Prop := (∑ v ∈ B.holders, B.rem v) = B.target

/-- per-vault credit when distributing `amt` freed HOLLAR: pro-rata by `rem`, capped at `rem`
(the on-chain `cut = min(freed·rem/target, rem)`). -/
noncomputable def cut (B : RedeemBook Vault) (amt : ℝ) (v : Vault) : ℝ :=
  min (amt * B.rem v / B.target) (B.rem v)

/-- total distributed by `_creditFreed(amt)`. -/
noncomputable def distributed (B : RedeemBook Vault) (amt : ℝ) : ℝ :=
  ∑ v ∈ B.holders, B.cut amt v

/-! ## No over-credit (the headline) -/

/-- **`_creditFreed` cannot over-credit:** under `TargetMatched` it distributes at most `amt` — the
freed HOLLAR it was handed. So `reservedFreed` never overstates the loop's actual HOLLAR. -/
theorem creditFreed_no_over_credit (B : RedeemBook Vault) (amt : ℝ)
    (hT : 0 < B.target) (hmatch : B.TargetMatched) :
    B.distributed amt ≤ amt := by
  have step : B.distributed amt ≤ ∑ v ∈ B.holders, amt * B.rem v / B.target :=
    Finset.sum_le_sum (fun v _ => min_le_left _ _)
  refine step.trans (le_of_eq ?_)
  have hfac : ∀ v ∈ B.holders, amt * B.rem v / B.target = (amt / B.target) * B.rem v := by
    intro v _; ring
  rw [Finset.sum_congr rfl hfac, ← Finset.mul_sum, hmatch]
  field_simp

/-! ## The buggy weighting over-credits (bug G, formalized) -/

/-- The BUGGY per-vault credit: pro-rata by raw `requested` (not `rem`). -/
noncomputable def cutBuggy (B : RedeemBook Vault) (amt : ℝ) (v : Vault) : ℝ :=
  amt * B.requested v / B.target

noncomputable def distributedBuggy (B : RedeemBook Vault) (amt : ℝ) : ℝ :=
  ∑ v ∈ B.holders, B.cutBuggy amt v

/-- **Bug G:** the raw-`requested` weighting distributes `amt + (amt/target)·Σ freed` — strictly more
than `amt` once any vault has been credited-but-not-pulled (`Σ freed > 0`). That surplus is what made
`reservedFreed` overstate the balance and pulls revert. -/
theorem buggy_over_credits (B : RedeemBook Vault) (amt : ℝ)
    (hT : 0 < B.target) (hmatch : B.TargetMatched) :
    B.distributedBuggy amt = amt + (amt / B.target) * (∑ v ∈ B.holders, B.freed v) := by
  have hfac : ∀ v ∈ B.holders, B.cutBuggy amt v = (amt / B.target) * B.rem v + (amt / B.target) * B.freed v := by
    intro v _; simp only [cutBuggy, rem]; ring
  rw [distributedBuggy, Finset.sum_congr rfl hfac, Finset.sum_add_distrib,
    ← Finset.mul_sum, ← Finset.mul_sum, hmatch]
  field_simp

/-- The surplus is strictly positive exactly when some equity is credited-but-unpulled. -/
theorem buggy_strictly_over (B : RedeemBook Vault) (amt : ℝ)
    (hT : 0 < B.target) (hamt : 0 < amt) (hmatch : B.TargetMatched)
    (hfreed : 0 < ∑ v ∈ B.holders, B.freed v) :
    amt < B.distributedBuggy amt := by
  rw [buggy_over_credits B amt hT hmatch]
  have : 0 < (amt / B.target) * (∑ v ∈ B.holders, B.freed v) :=
    mul_pos (div_pos hamt hT) hfreed
  linarith

/-! ## The book ops, and that `TargetMatched` is preserved -/

/-- A vault opens (extends) an unwind request: `requested[v] += e`, `target += e`. -/
def requestUnwind (v : Vault) (e : ℝ) (B : RedeemBook Vault) : RedeemBook Vault :=
  { B with requested := Function.update B.requested v (B.requested v + e),
           target := B.target + e }

/-- `_creditFreed(amt)`: credit each holder its `cut`, grow `reservedFreed`, shrink `target`. -/
noncomputable def creditFreed (amt : ℝ) (B : RedeemBook Vault) : RedeemBook Vault :=
  { B with freed := fun v => if v ∈ B.holders then B.freed v + B.cut amt v else B.freed v,
           reservedFreed := B.reservedFreed + B.distributed amt,
           target := B.target - B.distributed amt }

/-- A vault pulls its freed HOLLAR: `requested[v] -= freed[v]`, `freed[v] := 0`,
`reservedFreed -= freed[v]`. (`target` untouched — `rem v` is unchanged.) -/
def pull (v : Vault) (B : RedeemBook Vault) : RedeemBook Vault :=
  { B with requested := Function.update B.requested v (B.requested v - B.freed v),
           freed := Function.update B.freed v 0,
           reservedFreed := B.reservedFreed - B.freed v }

theorem requestUnwind_targetMatched (v : Vault) (e : ℝ) (B : RedeemBook Vault)
    (hv : v ∈ B.holders) (h : B.TargetMatched) : (B.requestUnwind v e).TargetMatched := by
  show (∑ w ∈ B.holders, (B.requestUnwind v e).rem w) = (B.requestUnwind v e).target
  rw [show (B.requestUnwind v e).target = B.target + e from rfl,
      show (∑ w ∈ B.holders, (B.requestUnwind v e).rem w)
          = ∑ w ∈ B.holders, (B.rem w + (if w = v then e else 0)) from
        Finset.sum_congr rfl (fun w _ => by
          simp only [requestUnwind, rem]
          rcases eq_or_ne w v with rfl | hw
          · rw [Function.update_self, if_pos rfl]; ring
          · rw [Function.update_of_ne hw, if_neg hw, add_zero]),
      Finset.sum_add_distrib, h, Finset.sum_ite_eq', if_pos hv]

theorem pull_targetMatched (v : Vault) (B : RedeemBook Vault) (h : B.TargetMatched) :
    (B.pull v).TargetMatched := by
  show (∑ w ∈ B.holders, (B.pull v).rem w) = (B.pull v).target
  rw [show (B.pull v).target = B.target from rfl,
      show (∑ w ∈ B.holders, (B.pull v).rem w) = ∑ w ∈ B.holders, B.rem w from
        Finset.sum_congr rfl (fun w _ => by
          simp only [pull, rem]
          rcases eq_or_ne w v with rfl | hw
          · rw [Function.update_self, Function.update_self]; ring
          · rw [Function.update_of_ne hw, Function.update_of_ne hw])]
  exact h

theorem creditFreed_targetMatched (amt : ℝ) (B : RedeemBook Vault) (h : B.TargetMatched) :
    (B.creditFreed amt).TargetMatched := by
  show (∑ w ∈ B.holders, (B.creditFreed amt).rem w) = (B.creditFreed amt).target
  rw [show (B.creditFreed amt).target = B.target - B.distributed amt from rfl,
      show (∑ w ∈ B.holders, (B.creditFreed amt).rem w) = ∑ w ∈ B.holders, (B.rem w - B.cut amt w) from
        Finset.sum_congr rfl (fun w hw => by simp only [creditFreed, rem, if_pos hw]; ring),
      Finset.sum_sub_distrib, h]
  rfl

/-- `creditFreed` raises `reservedFreed` by `distributed amt ≤ amt`: with `amt` ≤ the loop's
un-reserved HOLLAR, `reservedFreed` stays ≤ the balance — pulls never revert. -/
theorem creditFreed_reservedFreed_le (amt : ℝ) (B : RedeemBook Vault)
    (hT : 0 < B.target) (hmatch : B.TargetMatched) :
    (B.creditFreed amt).reservedFreed ≤ B.reservedFreed + amt := by
  simp only [creditFreed]
  have := creditFreed_no_over_credit B amt hT hmatch
  linarith

end RedeemBook

/-! ## Fixed-point (bytecode-arithmetic) refinement: the floored credit still can't over-credit

The reals above are the spec; the EVM computes `cut` with **floored** division —
`mulDivDown(freed, rem, target) = ⌊freed·rem/target⌋`, capped at `rem` (`SubLoop.sol`). This is the
integer counterpart of `creditFreed_no_over_credit`: with `ℕ` division (= EVM `div`), the floored
distribution still never exceeds `freed`, for **any** number of unwinders — so the bytecode arithmetic
the contract runs is conservative, not just the real-valued spec.

(The full ContractState-run model would require the unbounded `_creditFreed` loop *inside* the Verity
`SubLoop` cut, which exceeds Verity v0.1.0's loop support; this proves the safety-relevant arithmetic
the loop body executes, generalized over the whole unwinder set.) -/
theorem floored_credit_no_over_credit {Vault : Type*}
    (s : Finset Vault) (rem : Vault → ℕ) (freed target : ℕ)
    (hT : 0 < target) (hmatch : (∑ v ∈ s, rem v) = target) :
    (∑ v ∈ s, min (freed * rem v / target) (rem v)) ≤ freed := by
  -- each capped cut ≤ the floored share ⌊freed·rem_v/target⌋
  refine (Finset.sum_le_sum (fun v _ => min_le_left _ _)).trans ?_
  -- Σ ⌊freed·rem_v/target⌋ ≤ ⌊(Σ freed·rem_v)/target⌋  (ℕ: sum of floors ≤ floor of sum-over-c)
  have hsum : (∑ v ∈ s, freed * rem v / target) ≤ (∑ v ∈ s, freed * rem v) / target := by
    rw [Nat.le_div_iff_mul_le hT, Finset.sum_mul]
    exact Finset.sum_le_sum (fun v _ => Nat.div_mul_le_self _ _)
  refine hsum.trans ?_
  -- = ⌊freed·target/target⌋ = freed
  rw [← Finset.mul_sum, hmatch, Nat.mul_div_cancel _ hT]

end Propeller
