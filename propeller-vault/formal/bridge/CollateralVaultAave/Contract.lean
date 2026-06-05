import Contracts.Common

/-!
  Propeller `CollateralVault` — Aave-wired variant. Demonstrates the cross-contract / external-call
  path: `deposit` calls `IPool.supply` (Aave V3) before the 1:1 share accounting, mirroring the
  Solidity runtime step 2 ("Vault → Aave: supply collateral").

  The `IPool.supply` call is a typed-interface ECM → lowers to a real EVM `call` with the supply
  selector. It is **sound by assumption** on Aave's spec (the trust boundary; compile with
  `--deny-low-level-mechanics` + `--trust-report`). NOTE: Aave's real `supply` is `void`; Verity
  interface methods require a return type, so it is declared `returns (Bool)` and the value ignored
  — a one-line change once a void external-call ECM lands; the emitted `call` is the same.
-/

namespace Contracts

open Verity hiding pure bind
open Verity.EVM.Uint256
open Verity.Stdlib.Math

verity_contract CollateralVaultAave where
  storage
    totalAssetsSlot   : Uint256 := slot 0
    totalSupplySlot   : Uint256 := slot 1
    shareBalancesSlot : Address → Uint256 := slot 2

  interfaces
    interface IPool where
      function supply(Address, Uint256, Address, Uint256) returns (Bool)
    end

  constructor () := do
    setStorage totalAssetsSlot 0
    setStorage totalSupplySlot 0

  -- deposit collateral → supply it to Aave (external call) → mint shares 1:1.
  function deposit (pool : IPool, asset : Address, onBehalfOf : Address, assets : Uint256) : Unit := do
    let sender ← msgSender
    let _ok ← pool.supply asset assets onBehalfOf 0
    let currentShares ← getMapping shareBalancesSlot sender
    let newShares ← requireSomeUint (safeAdd currentShares assets) "VAULT: share overflow"
    let currentAssets ← getStorage totalAssetsSlot
    let newAssets ← requireSomeUint (safeAdd currentAssets assets) "VAULT: assets overflow"
    let currentSupply ← getStorage totalSupplySlot
    let newSupply ← requireSomeUint (safeAdd currentSupply assets) "VAULT: supply overflow"
    setMapping shareBalancesSlot sender newShares
    setStorage totalAssetsSlot newAssets
    setStorage totalSupplySlot newSupply

  function balanceOf (addr : Address) : Uint256 := do
    let s ← getMapping shareBalancesSlot addr
    return s

  function totalAssets () : Uint256 := do
    let a ← getStorage totalAssetsSlot
    return a

  function totalSupply () : Uint256 := do
    let t ← getStorage totalSupplySlot
    return t

end Contracts
