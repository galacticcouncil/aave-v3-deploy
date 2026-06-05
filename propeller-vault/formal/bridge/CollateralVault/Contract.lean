import Contracts.Common

/-!
  Propeller `CollateralVault` — per-collateral ERC4626 vault (see
  `propeller-vault/src/CollateralVault.sol` and the ℝ-spec in `propeller-vault/formal/`).

  This first cut models the **async-redemption share lifecycle** with 1:1 asset/share
  accounting (`deposit · requestRedeem · claim`), the distinctive CollateralVault surface.
  The Aave legs — `supply` collateral, `borrow` HOLLAR, `SyntheticToken.mint` — are external
  calls realized as ECMs (the documented next step; trust boundary). Forked from Verity's
  verified `Contracts/Vault`, with an escrow queue added.

  Invariant of record: `totalAssets == totalSupply` (1:1), preserved by deposit and claim;
  `requestRedeem` only moves shares balance→escrow and touches neither.
-/

namespace Contracts

open Verity hiding pure bind
open Verity.EVM.Uint256
open Verity.Stdlib.Math

verity_contract CollateralVault where
  storage
    totalAssetsSlot   : Uint256 := slot 0   -- collateral backing (1:1 with shares here)
    totalSupplySlot   : Uint256 := slot 1   -- outstanding shares
    shareBalancesSlot : Address → Uint256 := slot 2
    escrowSharesSlot  : Address → Uint256 := slot 3   -- shares locked by a pending redemption

  constructor () := do
    setStorage totalAssetsSlot 0
    setStorage totalSupplySlot 0

  -- deposit collateral → mint shares 1:1 (Aave supply + borrow + synth mint = ECMs, deferred)
  function deposit (assets : Uint256) : Unit := do
    let sender ← msgSender
    let currentShares ← getMapping shareBalancesSlot sender
    let newShares ← requireSomeUint (safeAdd currentShares assets) "VAULT: share overflow"
    let currentAssets ← getStorage totalAssetsSlot
    let newAssets ← requireSomeUint (safeAdd currentAssets assets) "VAULT: assets overflow"
    let currentSupply ← getStorage totalSupplySlot
    let newSupply ← requireSomeUint (safeAdd currentSupply assets) "VAULT: supply overflow"
    setMapping shareBalancesSlot sender newShares
    setStorage totalAssetsSlot newAssets
    setStorage totalSupplySlot newSupply

  -- escrow shares for redemption: move from free balance into the escrow queue
  function requestRedeem (shares : Uint256) : Unit := do
    let sender ← msgSender
    let currentShares ← getMapping shareBalancesSlot sender
    require (currentShares >= shares) "VAULT: insufficient shares"
    let currentEscrow ← getMapping escrowSharesSlot sender
    let newEscrow ← requireSomeUint (safeAdd currentEscrow shares) "VAULT: escrow overflow"
    setMapping shareBalancesSlot sender (sub currentShares shares)
    setMapping escrowSharesSlot sender newEscrow

  -- claim: burn escrowed shares and return collateral 1:1 (after the unwind/settle ECMs)
  function claim (shares : Uint256) : Unit := do
    let sender ← msgSender
    let currentEscrow ← getMapping escrowSharesSlot sender
    require (currentEscrow >= shares) "VAULT: insufficient escrow"
    let currentAssets ← getStorage totalAssetsSlot
    require (currentAssets >= shares) "VAULT: insufficient assets"
    let currentSupply ← getStorage totalSupplySlot
    require (currentSupply >= shares) "VAULT: insufficient supply"
    setMapping escrowSharesSlot sender (sub currentEscrow shares)
    setStorage totalAssetsSlot (sub currentAssets shares)
    setStorage totalSupplySlot (sub currentSupply shares)

  function balanceOf (addr : Address) : Uint256 := do
    let s ← getMapping shareBalancesSlot addr
    return s

  function escrowOf (addr : Address) : Uint256 := do
    let e ← getMapping escrowSharesSlot addr
    return e

  function totalAssets () : Uint256 := do
    let a ← getStorage totalAssetsSlot
    return a

  function totalSupply () : Uint256 := do
    let t ← getStorage totalSupplySlot
    return t

end Contracts
