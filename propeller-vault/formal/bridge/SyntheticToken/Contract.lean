import Contracts.Common

/-!
  Propeller `SyntheticToken` — the Aave reserve minted against the Main HOLLAR debt
  so the principal position is un-liquidatable (see `propeller-vault/src/SyntheticToken.sol`
  and the Lean spec in `propeller-vault/formal/`).

  On-chain it is a minimal ERC20 whose mint/burn are restricted to the vault
  (`onlyVault`). Its LTV-0 / LT-~98% / $1-oracle semantics are the Aave *reserve config*
  (REQ-SYNTH), not contract logic — on-chain it is just a soulbound balance the vault
  controls. Modelled on `Contracts/ERC20/ERC20.lean`.
-/

namespace Contracts

open Verity hiding pure bind
open Verity.EVM.Uint256
open Verity.Stdlib.Math

verity_contract SyntheticToken where
  storage
    vaultSlot       : Address := slot 0   -- sole minter/burner (the CollateralVault)
    totalSupplySlot : Uint256 := slot 1
    balancesSlot    : Address → Uint256 := slot 2

  constructor (vault : Address) := do
    setStorageAddr vaultSlot vault
    setStorage totalSupplySlot 0

  function mint (toAddr : Address, amount : Uint256) : Unit := do
    let sender ← msgSender
    let vault ← getStorageAddr vaultSlot
    require (sender == vault) "SYNTH: only vault"
    let currentBalance ← getMapping balancesSlot toAddr
    let newBalance ← requireSomeUint (safeAdd currentBalance amount) "SYNTH: balance overflow"
    let currentSupply ← getStorage totalSupplySlot
    let newSupply ← requireSomeUint (safeAdd currentSupply amount) "SYNTH: supply overflow"
    setMapping balancesSlot toAddr newBalance
    setStorage totalSupplySlot newSupply

  function burn (fromAddr : Address, amount : Uint256) : Unit := do
    let sender ← msgSender
    let vault ← getStorageAddr vaultSlot
    require (sender == vault) "SYNTH: only vault"
    let currentBalance ← getMapping balancesSlot fromAddr
    require (currentBalance >= amount) "SYNTH: burn exceeds balance"
    let currentSupply ← getStorage totalSupplySlot
    setMapping balancesSlot fromAddr (sub currentBalance amount)
    setStorage totalSupplySlot (sub currentSupply amount)

  function balanceOf (addr : Address) : Uint256 := do
    let currentBalance ← getMapping balancesSlot addr
    return currentBalance

  function totalSupply () : Uint256 := do
    let currentSupply ← getStorage totalSupplySlot
    return currentSupply

  function vault () : Address := do
    let v ← getStorageAddr vaultSlot
    return v

namespace SyntheticToken

def isVault : Contract Bool := do
  let sender ← msgSender
  let v ← getStorageAddr vaultSlot
  return sender == v

def onlyVault : Contract Unit := do
  let ok ← isVault
  require ok "SYNTH: only vault"

end SyntheticToken

end Contracts
