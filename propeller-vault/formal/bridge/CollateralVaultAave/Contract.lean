import Contracts.Common

/-!
  Propeller `CollateralVault` — Aave-wired variant. Demonstrates the cross-contract / external-call
  path: `deposit` mints shares 1:1 (effects), then **supplies the collateral to Aave and borrows
  HOLLAR against it** (interactions) — Solidity runtime step 2 ("Vault → Aave: supply ETH, then
  borrow HOLLAR ≤74% LTV").

  `IPool.supply` / `IPool.borrow` are typed-interface ECMs → each lowers to a real EVM `call` with the
  method selector. They are **sound by assumption** on Aave's spec (the trust boundary; compile with
  `--deny-low-level-mechanics` + `--trust-report`).

  NOTES / caveats (see bridge/AAVE_ECM_DIAGNOSIS.md):
  * Aave's real `supply`/`borrow` are `void`. They are declared here with **no `returns` clause**, so
    each lowers to the no-output `externalCallNoReturn` ECM: a selector+args `call(...)` that bubbles
    failure returndata but performs **no `returndatasize` check** and decodes no return value — exactly
    what a void callee (empty returndata) needs. `repay`/`withdraw` keep `returns (Uint256)`.
  * `referralCode` is `Uint16` (Aave V3), so all six emitted selectors match mainnet exactly (supply
    0x617ba037, borrow 0xa415bcad, …); calldata is byte-identical to a live Aave call.
  * Effects precede both external calls: Checks-Effects-Interactions, enforced by Verity's codegen.
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
    mainDebtSlot      : Uint256 := slot 3   -- hollar borrowed against the supplied collateral
    synthSupplySlot   : Uint256 := slot 4   -- synthetic minted (= tracks the main debt floor)
    -- deploy-side registry: keeper + canonical dependency addresses, set at construction.
    keeperSlot        : Address := slot 5   -- authorized caller of the keeper entrypoints
    poolRegSlot       : Address := slot 6   -- aave pool
    synthRegSlot      : Address := slot 7   -- SyntheticToken
    loopRegSlot       : Address := slot 8   -- SubLoop

  interfaces
    interface IPool where
      -- referralCode is uint16 (Aave V3) → emits the mainnet selectors (supply 0x617ba037,
      -- borrow 0xa415bcad). uint16 args still ABI-encode to a 32-byte word, so calldata is unchanged.
      -- void in real aave v3; declared with no returns clause → no-return ECM.
      function supply(Address, Uint256, Address, Uint16)
      function borrow(Address, Uint256, Uint256, Uint16, Address)
      -- repay / withdraw return uint256 in real Aave too, and take no uint16 → the emitted
      -- selectors match mainnet exactly (repay 0x573ade81, withdraw 0x69328dec).
      function repay(Address, Uint256, Uint256, Address) returns (Uint256)
      function withdraw(Address, Uint256, Address) returns (Uint256)
    end
    -- inter-contract surface: the vault drives its own SyntheticToken and the shared SubLoop.
    interface ISynth where
      function mint(Address, Uint256) returns (Bool)
    end
    interface ISubLoop where
      function deposit(Uint256) returns (Bool)
    end

  constructor (keeper : Address, poolAddr : Address, synthAddr : Address, loopAddr : Address) := do
    setStorage totalAssetsSlot 0
    setStorage totalSupplySlot 0
    setStorage mainDebtSlot 0
    setStorage synthSupplySlot 0
    setStorageAddr keeperSlot keeper
    setStorageAddr poolRegSlot poolAddr
    setStorageAddr synthRegSlot synthAddr
    setStorageAddr loopRegSlot loopAddr

  -- deposit collateral → mint shares 1:1 + record HOLLAR debt (effects) → supply collateral to
  -- Aave, then borrow HOLLAR against it (interactions). `borrowAmount` (≤ LTV·assets) and the
  -- HOLLAR asset are supplied by the caller; interestRateMode 2 = variable.
  --
  -- `allow_post_interaction_writes`: ALL storage writes precede BOTH external calls (true CEI);
  -- the only thing after the first call (`supply`) is the second call (`borrow`) to the SAME
  -- trusted Aave pool, with no storage write following either. Verity's CEI check is conservative
  -- about a second writing-ECM after any external call, so the annotation is required for the
  -- standard supply-then-borrow sequence. Reentrancy w.r.t. our own state is unaffected.
  -- full deposit flow (Solidity steps 2–4): mint shares + record debt & synthetic (effects), then
  -- supply collateral, borrow HOLLAR, mint the synthetic, and seed the SubLoop (interactions).
  function allow_post_interaction_writes deposit (pool : IPool, synth : ISynth, loop : ISubLoop,
      asset : Address, hollar : Address, onBehalfOf : Address,
      assets : Uint256, borrowAmount : Uint256, synthAmount : Uint256) : Unit := do
    let sender ← msgSender
    let currentShares ← getMapping shareBalancesSlot sender
    let newShares ← requireSomeUint (safeAdd currentShares assets) "VAULT: share overflow"
    let currentAssets ← getStorage totalAssetsSlot
    let newAssets ← requireSomeUint (safeAdd currentAssets assets) "VAULT: assets overflow"
    let currentSupply ← getStorage totalSupplySlot
    let newSupply ← requireSomeUint (safeAdd currentSupply assets) "VAULT: supply overflow"
    let currentDebt ← getStorage mainDebtSlot
    let newDebt ← requireSomeUint (safeAdd currentDebt borrowAmount) "VAULT: debt overflow"
    let currentSynth ← getStorage synthSupplySlot
    let newSynth ← requireSomeUint (safeAdd currentSynth synthAmount) "VAULT: synth overflow"
    setMapping shareBalancesSlot sender newShares
    setStorage totalAssetsSlot newAssets
    setStorage totalSupplySlot newSupply
    setStorage mainDebtSlot newDebt
    setStorage synthSupplySlot newSynth
    pool.supply asset assets onBehalfOf 0
    pool.borrow hollar borrowAmount 2 0 onBehalfOf
    let _minted ← synth.mint onBehalfOf synthAmount           -- CollateralVault → SyntheticToken
    let _seeded ← loop.deposit borrowAmount                   -- CollateralVault → SubLoop

  -- unwind/settle (Solidity step 5): repay HOLLAR debt, then withdraw freed collateral from Aave.
  -- Effects (lower debt + shares + assets) precede both interactions; same CEI annotation as deposit.
  function allow_post_interaction_writes pokeSettle (pool : IPool, hollar : Address, asset : Address,
      onBehalfOf : Address, recipient : Address, repayAmount : Uint256, withdrawAmount : Uint256) : Unit := do
    -- deploy-side access control: only the registered keeper drives settlement.
    let sender ← msgSender
    let k ← getStorageAddr keeperSlot
    require (sender == k) "VAULT: only keeper"
    let currentDebt ← getStorage mainDebtSlot
    require (currentDebt >= repayAmount) "VAULT: repay exceeds debt"
    let currentAssets ← getStorage totalAssetsSlot
    require (currentAssets >= withdrawAmount) "VAULT: withdraw exceeds assets"
    let currentSupply ← getStorage totalSupplySlot
    require (currentSupply >= withdrawAmount) "VAULT: withdraw exceeds supply"
    setStorage mainDebtSlot (sub currentDebt repayAmount)
    setStorage totalAssetsSlot (sub currentAssets withdrawAmount)
    setStorage totalSupplySlot (sub currentSupply withdrawAmount)
    let _repaid ← pool.repay hollar repayAmount 2 onBehalfOf
    let _withdrawn ← pool.withdraw asset withdrawAmount recipient

  -- deploy-side registry getters.
  function keeper () : Address := do
    let k ← getStorageAddr keeperSlot
    return k

  function poolAddress () : Address := do
    let a ← getStorageAddr poolRegSlot
    return a

  function synthAddress () : Address := do
    let a ← getStorageAddr synthRegSlot
    return a

  function loopAddress () : Address := do
    let a ← getStorageAddr loopRegSlot
    return a

  function balanceOf (addr : Address) : Uint256 := do
    let s ← getMapping shareBalancesSlot addr
    return s

  function totalAssets () : Uint256 := do
    let a ← getStorage totalAssetsSlot
    return a

  function totalSupply () : Uint256 := do
    let t ← getStorage totalSupplySlot
    return t

  function mainDebt () : Uint256 := do
    let d ← getStorage mainDebtSlot
    return d

end Contracts
