import Contracts.Common

/-!
  Propeller `SubLoop` — the single shared PRIME-isolation leveraged loop (see
  `propeller-vault/src/SubLoop.sol` and the ℝ-spec in `propeller-vault/formal/`).

  Per the gradual-DCA design there is **no in-contract loop**: each keeper call does one
  step (`pokeBorrow` / `pokeRepay`), and the ~6× leverage is reached over many transactions.

  This cut models the loop's internal accounting. Its distinctive property — proven in
  `Proofs.lean` — is **equity-neutrality**: borrowing HOLLAR to buy PRIME (`pokeBorrow`) and the
  reverse (`pokeRepay`) move `primeAmt` and `subDebt` by the *same* amount, so loop equity
  (`primeAmt − subDebt`) is invariant; only leverage changes. This is exactly why the loop's risk
  is rate-spread (carry), not price-gap. The actual Aave borrow/repay + PRIME swap are ECMs (next).
-/

namespace Contracts

open Verity hiding pure bind
open Verity.EVM.Uint256
open Verity.Stdlib.Math

verity_contract SubLoop where
  storage
    primeAmtSlot      : Uint256 := slot 0   -- aPRIME supplied (loop collateral)
    subDebtSlot       : Uint256 := slot 1   -- HOLLAR borrowed in the loop
    totalSharesSlot   : Uint256 := slot 2   -- equity shares across all vaults
    shareBalancesSlot : Address → Uint256 := slot 3   -- per-vault equity shares
    controllerSlot    : Address := slot 4   -- authorized poker (the keeper / harvester)

  constructor (controller : Address) := do
    setStorage primeAmtSlot 0
    setStorage subDebtSlot 0
    setStorage totalSharesSlot 0
    setStorageAddr controllerSlot controller

  -- a vault seeds the loop with HOLLAR-equivalent equity → mints equity shares 1:1.
  -- (seed buys PRIME: primeAmt += seed; subDebt unchanged ⇒ equity += seed.)
  function deposit (seed : Uint256) : Unit := do
    let sender ← msgSender
    let currentShares ← getMapping shareBalancesSlot sender
    let newShares ← requireSomeUint (safeAdd currentShares seed) "LOOP: share overflow"
    let currentPrime ← getStorage primeAmtSlot
    let newPrime ← requireSomeUint (safeAdd currentPrime seed) "LOOP: prime overflow"
    let currentSupply ← getStorage totalSharesSlot
    let newSupply ← requireSomeUint (safeAdd currentSupply seed) "LOOP: supply overflow"
    setMapping shareBalancesSlot sender newShares
    setStorage primeAmtSlot newPrime
    setStorage totalSharesSlot newSupply

  -- keeper step UP: borrow `amount` HOLLAR, buy PRIME. Both legs grow equally ⇒ equity neutral.
  -- onlyController: only the registered keeper/harvester may move leverage.
  function pokeBorrow (amount : Uint256) : Unit := do
    let sender ← msgSender
    let ctrl ← getStorageAddr controllerSlot
    require (sender == ctrl) "LOOP: only controller"
    let currentPrime ← getStorage primeAmtSlot
    let newPrime ← requireSomeUint (safeAdd currentPrime amount) "LOOP: prime overflow"
    let currentDebt ← getStorage subDebtSlot
    let newDebt ← requireSomeUint (safeAdd currentDebt amount) "LOOP: debt overflow"
    setStorage primeAmtSlot newPrime
    setStorage subDebtSlot newDebt

  -- keeper step DOWN: sell PRIME, repay `amount` HOLLAR. Both legs shrink equally ⇒ equity neutral.
  -- onlyController: only the registered keeper/harvester may move leverage.
  function pokeRepay (amount : Uint256) : Unit := do
    let sender ← msgSender
    let ctrl ← getStorageAddr controllerSlot
    require (sender == ctrl) "LOOP: only controller"
    let currentPrime ← getStorage primeAmtSlot
    require (currentPrime >= amount) "LOOP: prime underflow"
    let currentDebt ← getStorage subDebtSlot
    require (currentDebt >= amount) "LOOP: debt underflow"
    setStorage primeAmtSlot (sub currentPrime amount)
    setStorage subDebtSlot (sub currentDebt amount)

  -- a vault schedules unwinding `shares` of its equity (burns its loop shares).
  function requestUnwind (shares : Uint256) : Unit := do
    let sender ← msgSender
    let currentShares ← getMapping shareBalancesSlot sender
    require (currentShares >= shares) "LOOP: insufficient shares"
    let currentSupply ← getStorage totalSharesSlot
    require (currentSupply >= shares) "LOOP: insufficient supply"
    setMapping shareBalancesSlot sender (sub currentShares shares)
    setStorage totalSharesSlot (sub currentSupply shares)

  function primeAmt () : Uint256 := do
    let p ← getStorage primeAmtSlot
    return p

  function subDebt () : Uint256 := do
    let d ← getStorage subDebtSlot
    return d

  function totalShares () : Uint256 := do
    let t ← getStorage totalSharesSlot
    return t

  function balanceOf (addr : Address) : Uint256 := do
    let s ← getMapping shareBalancesSlot addr
    return s

end Contracts
