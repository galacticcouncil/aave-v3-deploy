import Mathlib

-- a single shared `variable` block carries `[DecidableEq Vault]` for the ops that need
-- `Function.update`; the poke/claim lemmas don't use it. That's intentional, so silence the lint.
set_option linter.unusedSectionVars false

/-!
# Propeller — multi-vault shared SubLoop (share accounting)

The on-chain `SubLoop` is **one** leveraged PRIME-isolation loop shared by **many** vaults: each
vault that seeds it holds per-vault equity `shares`, tracked alongside a single aggregate
`primeAmt`/`subDebt` and a separately-stored `totalShares`. The single-position `SubLoop.lean` cut
models one aggregate position and so cannot express the *shared-book* properties. This file does.

Proven (all axiom-clean):
* **conservation** — `∑ per-vault shares = totalShares`, preserved by `deposit` / `requestUnwind`
  (and trivially by the keeper pokes, which never touch the book);
* **isolation** — a vault's `deposit` / `requestUnwind` touches **only its own** share entry — the
  "PRIME-isolation" claim: no cross-vault contamination;
* **equity-neutral pokes** — `pokeBorrow`/`pokeRepay` leave `loopEquity` invariant and the book
  untouched;
* **pro-rata** — the per-vault equity claims exactly **tile** `loopEquity` (no equity created or lost
  in the multi-vault split).

`shares : Vault → ℝ` over a fixed registry `holders` (vaults outside `holders` hold 0); `totalShares`
is stored separately (as on-chain), so conservation is a real theorem, not a definitional identity.
-/

namespace Propeller

open scoped BigOperators

/-- One shared PRIME-isolation loop with a per-vault equity-share book. Mirrors the on-chain
`SubLoop`: aggregate `primeAmt`/`subDebt`, a stored `totalShares`, and `shares` over the registry
`holders`. -/
structure LoopState (Vault : Type*) where
  /-- aPRIME supplied across the whole loop. -/
  primeAmt    : ℝ
  /-- PRIME price (value-stable, ≈ 1). -/
  primePrice  : ℝ
  /-- Aave liquidation threshold of PRIME. -/
  ltPrime     : ℝ
  /-- HOLLAR debt of the loop. -/
  subDebt     : ℝ
  /-- stored total of all vaults' shares (a separate slot on-chain). -/
  totalShares : ℝ
  /-- the vault registry: the finite set of vaults that may hold shares. -/
  holders     : Finset Vault
  /-- per-vault equity-share book (0 outside `holders`). -/
  shares      : Vault → ℝ

namespace LoopState

variable {Vault : Type*} [DecidableEq Vault]

/-- Value-stable loop equity = PRIME collateral value − loop debt (HOLLAR-equiv). -/
def loopEquity (L : LoopState Vault) : ℝ := L.primeAmt * L.primePrice - L.subDebt

/-- **Conservation invariant:** the per-vault share book sums to the stored total. -/
def Conserved (L : LoopState Vault) : Prop := (∑ v ∈ L.holders, L.shares v) = L.totalShares

/-- Pro-rata equity claim of vault `v`: its share of `loopEquity`. -/
noncomputable def claim (L : LoopState Vault) (v : Vault) : ℝ :=
  (L.shares v / L.totalShares) * L.loopEquity

/-- A vault seeds the loop: mint `seed` shares 1:1, buy PRIME (`primeAmt += seed`); `subDebt`
unchanged ⇒ equity grows by `seed·primePrice`. Mirrors `SubLoop.deposit`. -/
def deposit (v : Vault) (seed : ℝ) (L : LoopState Vault) : LoopState Vault :=
  { L with primeAmt := L.primeAmt + seed,
           totalShares := L.totalShares + seed,
           shares := Function.update L.shares v (L.shares v + seed) }

/-- A vault burns `amt` of its shares (and the stored total). `primeAmt`/`subDebt` untouched — the
value move is a later keeper poke. Mirrors `SubLoop.requestUnwind`. -/
def requestUnwind (v : Vault) (amt : ℝ) (L : LoopState Vault) : LoopState Vault :=
  { L with totalShares := L.totalShares - amt,
           shares := Function.update L.shares v (L.shares v - amt) }

/-- Keeper step UP (value-matched): supply `a` aPRIME, borrow `a·primePrice` HOLLAR. -/
def pokeBorrow (a : ℝ) (L : LoopState Vault) : LoopState Vault :=
  { L with primeAmt := L.primeAmt + a, subDebt := L.subDebt + a * L.primePrice }

/-- Keeper step DOWN (value-matched): sell `a` aPRIME, repay `a·primePrice` HOLLAR. -/
def pokeRepay (a : ℝ) (L : LoopState Vault) : LoopState Vault :=
  { L with primeAmt := L.primeAmt - a, subDebt := L.subDebt - a * L.primePrice }

/-! ## Conservation -/

/-- `deposit` preserves conservation: it adds `seed` to both the depositor's entry and the total. -/
theorem deposit_conserved (v : Vault) (seed : ℝ) (L : LoopState Vault)
    (hv : v ∈ L.holders) (h : L.Conserved) : (L.deposit v seed).Conserved := by
  have hupd : ∀ w ∈ L.holders,
      Function.update L.shares v (L.shares v + seed) w = L.shares w + (if w = v then seed else 0) := by
    intro w _; rcases eq_or_ne w v with rfl | hw
    · simp
    · rw [Function.update_of_ne hw, if_neg hw, add_zero]
  unfold Conserved deposit
  simp only
  rw [Finset.sum_congr rfl hupd, Finset.sum_add_distrib, h, Finset.sum_ite_eq', if_pos hv]

/-- `requestUnwind` preserves conservation: it subtracts `amt` from both the vault's entry and the
total. -/
theorem requestUnwind_conserved (v : Vault) (amt : ℝ) (L : LoopState Vault)
    (hv : v ∈ L.holders) (h : L.Conserved) : (L.requestUnwind v amt).Conserved := by
  have hupd : ∀ w ∈ L.holders,
      Function.update L.shares v (L.shares v - amt) w = L.shares w + (if w = v then -amt else 0) := by
    intro w _; rcases eq_or_ne w v with rfl | hw
    · simp [sub_eq_add_neg]
    · rw [Function.update_of_ne hw, if_neg hw, add_zero]
  unfold Conserved requestUnwind
  simp only
  rw [Finset.sum_congr rfl hupd, Finset.sum_add_distrib, h, Finset.sum_ite_eq', if_pos hv]
  ring

/-- Keeper pokes never touch the share book, so conservation is trivially preserved. -/
theorem pokeBorrow_conserved (a : ℝ) (L : LoopState Vault) (h : L.Conserved) :
    (L.pokeBorrow a).Conserved := h

theorem pokeRepay_conserved (a : ℝ) (L : LoopState Vault) (h : L.Conserved) :
    (L.pokeRepay a).Conserved := h

/-! ## Isolation — an op touches only the acting vault's entry -/

theorem deposit_isolation (v w : Vault) (seed : ℝ) (L : LoopState Vault) (hwv : w ≠ v) :
    (L.deposit v seed).shares w = L.shares w :=
  Function.update_of_ne hwv _ _

theorem requestUnwind_isolation (v w : Vault) (amt : ℝ) (L : LoopState Vault) (hwv : w ≠ v) :
    (L.requestUnwind v amt).shares w = L.shares w :=
  Function.update_of_ne hwv _ _

/-- The pokes leave the entire share book fixed. -/
theorem pokeBorrow_shares (a : ℝ) (L : LoopState Vault) : (L.pokeBorrow a).shares = L.shares := rfl

theorem pokeRepay_shares (a : ℝ) (L : LoopState Vault) : (L.pokeRepay a).shares = L.shares := rfl

/-! ## Equity-neutral keeper pokes -/

theorem pokeBorrow_loopEquity (a : ℝ) (L : LoopState Vault) :
    (L.pokeBorrow a).loopEquity = L.loopEquity := by
  simp only [loopEquity, pokeBorrow]; ring

theorem pokeRepay_loopEquity (a : ℝ) (L : LoopState Vault) :
    (L.pokeRepay a).loopEquity = L.loopEquity := by
  simp only [loopEquity, pokeRepay]; ring

/-! ## Pro-rata — the per-vault claims tile the loop equity -/

/-- **No equity created or lost in the split:** summing every vault's pro-rata `claim` recovers the
loop equity exactly (given conservation and a non-zero total). -/
theorem claims_partition_equity (L : LoopState Vault) (h : L.Conserved) (hT : L.totalShares ≠ 0) :
    (∑ v ∈ L.holders, L.claim v) = L.loopEquity := by
  simp only [claim]
  rw [← Finset.sum_mul, ← Finset.sum_div, h, div_self hT, one_mul]

end LoopState
end Propeller
