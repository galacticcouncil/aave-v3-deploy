# Entry Point Map

> Propeller | 35 entry points | 12 permissionless · 1 owner-gated · 5 role-gated · 15 admin/guardian · 2 initializers

Excludes inherited OpenZeppelin surface (ERC20 `transfer`/`approve`/`transferFrom`, `AccessControl.grantRole`/`revokeRole`/`renounceRole`, `UUPSUpgradeable.upgradeTo`/`upgradeToAndCall`) except where noted in Initialization.

---

## Protocol Flow Paths

### Setup (Governance, one Root batch)

```
DeploySynth → DeployMain → DeployHarvester → DeployVaultTBTC
  └─ assetRegistry.register(synth, Erc20) → PoolConfigurator.initReserves(synth)
       → configureReserveAsCollateral(LTV 100, LT 9800) → setReserveBorrowing(false)
       → AaveOracle.setAssetSources(synth, $1)
         → SyntheticToken.grantRole(MINTER_ROLE, vault)
         → SubLoop.registerVault(vault)        ◄── grants VAULT_ROLE
         → SubLoop.setTranches(deploy, unwind) ◄── 0 tranche ⇒ pokeBorrow unbounded
         → SubLoop.configureDca(222, 43, 1043, 143, ppm)
         → SubLoop.setHarvester(harvester)     ◄── unset ⇒ harvest pays msg.sender
         → CollateralVault.setCompoundSlippageBps(bps) ◄── 0 ⇒ compound always reverts
         → Harvester.addVault(vault)
```

`CollateralVault.setYieldSource` also belongs to this phase and **only** this phase — see Admin-Only.

### User Flow

```
[governance setup above] → CollateralVault.deposit()   ◄── !depositsPaused, !paused, totalAssets+assets ≤ tvlCap
                                  │                     ◄── collateral reserve maxLtv > 0 (else borrow(0) reverts)
                                  ├─→ requestRedeem()  ◄── yieldSource.equityOf(vault) > 0 (else NoLoopEquity)
                                  │      │              ◄── so the loop must be ramped first
                                  │      └─→ [SubLoop.pokeRepay frees equity] → pokeSettle() → claim()
                                  └─→ (hold; share price rises via harvest → compound)
```

### Loop Ramp (Anyone / looper bot)

```
[deposit above] → SubLoop.pokeBorrow()  ◄── aPRIME balance > 0 to enable collateral flag
                       └─ repeat until maxDebt8 ≤ debtBase8 (HF at deployHfFloor ≈ 1.05)
```

Also a precondition for redeeming: an un-ramped loop reports `totalEquity() == 0` because
PRIME is an isolation-mode reserve and a plain supply never auto-enables it as collateral.

### Yield Realisation (Anyone)

```
[pokeBorrow ramp above] → [PRIME supply APY accrues, equity > principalEquity + unwindTargetEquity]
   → Harvester.harvest(minOuts)
        └─ SubLoop.harvest()          ◄── surplus18·WAD ≥ principalEquity·harvestThreshold
             └─ CollateralVault.compound() per vault  ◄── vault not paused; swapper must be live
                  └─ pool.supply(collateral) ⇒ exchangeRate ↑
```

### Maintenance (Anyone)

```
[deposit above] → maintainPeg()   ◄── synth·LT drifted below Main debt (interest accrual)
                → rebalance()     ◄── |LTV − reserve maxLtv| outside −500/+300 bps band
                       ├─ up:   borrow → mint synth → SubLoop.deposit()
                       └─ down: SubLoop.requestUnwind(slice) → deleverTarget += repay
                                  ◄── capped at non-queued debt AND at loop equity
                → SubLoop.deLever()  ◄── HF ≤ deLeverTrigger (1.10) and HF < targetHf
                       └─ SubLoop.pokeRepay() drains deleverDebtTarget
                                  ◄── inoperable below HF 1.02: the sell gate never opens
```

### Spiral Termination (Anyone)

```
SubLoop.pokeRepay()
  ├─ sells while HF headroom exists and the sliver is ≥ 1 unit of 6dp aPRIME
  ├─ [headroom exists but sliver floors to 0]  → _closeOutUnrealizableUnwinds()
  ├─ [aPRIME balance reaches 0]                → _closeOutUnrealizableUnwinds()
  └─ then CollateralVault.pokeSettle() → _retireExhaustedHead()
        ◄── source owes nothing, availableHollar == 0, head.repaid > 0
        ⇒ head.debtShare snapped down to head.repaid, queueHead advances
```

There is **no** admin emergency wind-down. To stop flow into a source: `pause()` (guardian).

---

## Permissionless

### `CollateralVault.deposit()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Depositor |
| Parameters | `assets` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ IERC20.safeTransferFrom → AavePool.supply → AavePool.borrow → SyntheticToken.mint → AavePool.supply → AavePool.setUserUseReserveAsCollateral → SubLoop.deposit → DcaDispatch.routerSell` |
| State modified | `_balances`, `_totalSupply`, `syntheticSupplied`, `loopShares` |
| Value flow | collateral: sender → Vault → Aave; HOLLAR: Aave → Vault → SubLoop |
| Reentrancy guard | yes |

### `CollateralVault.requestRedeem()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Share holder or ERC20-approved spender |
| Parameters | `shares` (user-controlled), `owner` (user-controlled; `_spendAllowance` if `msg.sender != owner`) |
| Call chain | `→ SubLoop.equityOf → CollateralVault._transfer(owner → this) → SubLoop.requestUnwind` |
| State modified | `redemptions[id]`, `queueTail`, `totalQueuedShares`, `totalQueuedDebt`, `loopShares` |
| Value flow | shares: owner → Vault (escrow) |
| Reentrancy guard | yes |
| Notable guard | reverts `NoLoopEquity` when `yieldSource.equityOf(vault) == 0` — a zero-equity source would record a zero unwind target and orphan the request |

### `CollateralVault.pokeSettle()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**not** whenNotPaused) |
| Caller | Looper bot / anyone |
| Parameters | none |
| Call chain | `→ SubLoop.pullFreed → AavePool.repay → AavePool.withdraw(synth) → SyntheticToken.burn → AavePool.withdraw(collateral) → CollateralVault._retireExhaustedHead → SubLoop.pendingUnwindOf/freedOf` |
| State modified | `availableHollar`, `deleverTarget`, `syntheticSupplied`, `redemptions[*]`, `queueHead`, `totalQueuedDebt` |
| Value flow | HOLLAR: SubLoop → Vault → Aave; collateral: Aave → Vault |
| Reentrancy guard | yes |

### `CollateralVault.compound()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Harvester (normally) / anyone |
| Parameters | `tokenIn` (user-controlled), `amountIn` (user-controlled), `minCollateralOut` (user-controlled, floored to oracle-fair), `route` (user-controlled, opaque) |
| Call chain | `→ IERC20.safeTransferFrom → CollateralVault._fairCollateralOut → AaveOracle.getAssetPrice ×2 → ISwapper.sell → AavePool.supply` |
| State modified | none directly; grows `collateralAToken` balance ⇒ `exchangeRate` |
| Value flow | tokenIn: caller → Vault; collateral: swapper → Vault → Aave |
| Reentrancy guard | yes |

### `CollateralVault.rebalance()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Looper bot / anyone |
| Parameters | none |
| Call chain | up: `→ AavePool.borrow → SyntheticToken.mint → AavePool.supply → SubLoop.deposit`; down: `→ SubLoop.equityOf → SubLoop.requestUnwind` |
| State modified | `syntheticSupplied`, `loopShares`, `deleverTarget` |
| Value flow | HOLLAR: Aave → Vault → SubLoop (up-branch only) |
| Reentrancy guard | yes |
| Notable guard | de-lever branch caps `repay8` at both the non-queued Main debt and the vault's live loop equity |

### `CollateralVault.maintainPeg()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**not** whenNotPaused) |
| Caller | Looper bot / anyone |
| Parameters | none |
| Call chain | `→ SyntheticToken.mint → AavePool.supply → AavePool.setUserUseReserveAsCollateral` |
| State modified | `syntheticSupplied` |
| Value flow | synth: Vault → Aave |
| Reentrancy guard | yes |

### `SubLoop.pokeBorrow()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Looper bot / anyone |
| Parameters | none |
| Call chain | `→ AavePool.setUserUseReserveAsCollateral → AavePool.getUserAccountData → AavePool.borrow → SubLoop._fundDeploy → AaveOracle.getAssetPrice ×2 → DcaDispatch.routerSell` |
| State modified | none in SubLoop; Aave debt + aPRIME collateral grow |
| Value flow | HOLLAR: Aave → SubLoop → router → aPRIME |
| Reentrancy guard | yes |

### `SubLoop.pokeRepay()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**not** whenNotPaused) |
| Caller | Looper bot / anyone |
| Parameters | none |
| Call chain | `→ AaveOracle.getAssetPrice ×2 → DcaDispatch.routerSell(aPRIME→HOLLAR) → AavePool.repay → SubLoop._creditFreed → SubLoop._closeOutUnrealizableUnwinds` |
| State modified | `deleverDebtTarget`, `freedHollar[*]`, `reservedFreed`, `unwindTargetEquity`, `unwindRequested[*]`, `_unwinders` |
| Value flow | aPRIME → HOLLAR → Aave repay; remainder reserved for vaults |
| Reentrancy guard | yes |

### `SubLoop.harvest()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant, whenNotPaused |
| Caller | Harvester (normally) / anyone |
| Parameters | none |
| Call chain | `→ AaveOracle.getAssetPrice ×2 → AavePool.withdraw(prime) → IERC20.safeTransfer(harvester ?: msg.sender)` |
| State modified | none in SubLoop; aPRIME collateral shrinks |
| Value flow | PRIME: Aave → SubLoop → `harvester`, or → `msg.sender` when `harvester == address(0)` |
| Reentrancy guard | yes |

### `SubLoop.deLever()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**not** whenNotPaused) |
| Caller | Harvester / anyone |
| Parameters | none |
| Call chain | `→ AavePool.getUserAccountData` (target only; spiral runs in `pokeRepay`) |
| State modified | `deleverDebtTarget` |
| Value flow | none |
| Reentrancy guard | yes |

### `Harvester.harvest()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (no guard, no reentrancy guard) |
| Caller | Looper bot / anyone |
| Parameters | `minOuts[]` (user-controlled; each is floored inside `CollateralVault.compound`) |
| Call chain | `→ SubLoop.harvest → IERC20.forceApprove → CollateralVault.compound` (per registered vault) |
| State modified | none in Harvester |
| Value flow | PRIME: SubLoop → Harvester → each Vault |
| Reentrancy guard | no |

### `Harvester.deLever()`

| Aspect | Detail |
|--------|--------|
| Visibility | external (no guard) |
| Caller | Anyone |
| Parameters | none |
| Call chain | `→ SubLoop.deLever` |
| State modified | none |
| Value flow | none |
| Reentrancy guard | no |

---

## Owner-Gated (no modifier; `msg.sender` checked in body)

### `CollateralVault.claim()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant (**not** whenNotPaused); `if (msg.sender != r.owner) revert NotRequestOwner()` |
| Caller | The request owner recorded at `requestRedeem` |
| Parameters | `requestId` (user-controlled), `receiver` (user-controlled) |
| Call chain | `→ CollateralVault._burn(this) → IERC20.safeTransfer(receiver)` |
| State modified | `redemptions[id].collateralSettled/sharesBurned/active`, `totalQueuedShares`, `_totalSupply` |
| Value flow | collateral: Vault → receiver |
| Reentrancy guard | yes |

---

## Role-Gated

### `VAULT_ROLE` (granted by `SubLoop.registerVault`)

| Contract | Function | Parameters | Call chain | Value flow |
|----------|----------|------------|------------|-----------|
| SubLoop | `deposit()` | `hollarAmount` (protocol-derived) | `→ IERC20.safeTransferFrom → SubLoop._fundDeploy → DcaDispatch.routerSell` | HOLLAR: Vault → SubLoop |
| SubLoop | `requestUnwind()` | `shares` (protocol-derived) | `→ AavePool.getUserAccountData` | none (records target) |
| SubLoop | `pullFreed()` | none | `→ IERC20.safeTransfer` | HOLLAR: SubLoop → Vault |

State modified: `_sharesOf`, `_totalShares`, `principalEquity`, `unwindRequested`, `unwindTargetEquity`, `_unwinders`, `freedHollar`, `reservedFreed`, `unwindOrderId`. All three are `nonReentrant`; `deposit` is also `whenNotPaused`. `requestUnwind` deliberately accepts a zero-equity slice — the caller-side guard lives in `CollateralVault.requestRedeem`.

### `MINTER_ROLE` (granted to each CollateralVault)

| Contract | Function | Parameters | Value flow |
|----------|----------|------------|-----------|
| SyntheticToken | `mint()` | `to`, `amount` (protocol-derived) | mints psHOLLAR |
| SyntheticToken | `burn()` | `from`, `amount` (protocol-derived) | burns psHOLLAR |

---

## Admin-Only

| Contract | Function | Role | Parameters | State Modified |
|----------|----------|------|------------|----------------|
| CollateralVault | `setTvlCap()` | ADMIN_ROLE | `newCap` | `tvlCap` (no floor check vs `totalAssets`) |
| CollateralVault | `setYieldSource()` | ADMIN_ROLE | `newSource` | `yieldSource`, `availableHollar`. **Deploy-time only** — requires `loopShares == 0 && sharesOf == 0 && pendingUnwindOf == 0`, and `DEAD_SHARES` keep `loopShares` permanently non-zero once funded, so a live vault can never satisfy it |
| CollateralVault | `setCompoundSlippageBps()` | ADMIN_ROLE | `bps` (`< 10000`) | `compoundSlippageBps` |
| CollateralVault | `pauseDeposits()` / `unpauseDeposits()` | GUARDIAN_ROLE | none | `depositsPaused` |
| CollateralVault | `pause()` / `unpause()` | GUARDIAN_ROLE | none | `_paused` |
| SubLoop | `registerVault()` | ADMIN_ROLE | `vault` | grants `VAULT_ROLE` (no revoke helper) |
| SubLoop | `setTranches()` | ADMIN_ROLE | `_deployTranche`, `_unwindTranche` | `deployTranche`, `unwindTranche` |
| SubLoop | `configureDca()` | ADMIN_ROLE | `_hollarAssetId`, `_primeAssetId`, `_aPrimeAssetId`, `_primePoolId`, `_slippagePpm` | route ids + `dcaSlippagePpm` (no bounds check) |
| SubLoop | `setParams()` | ADMIN_ROLE | `_targetHf`, `_deployHfFloor`, `_deLeverTrigger`, `_harvestThreshold` | all four (no bounds check) |
| SubLoop | `setHarvester()` | ADMIN_ROLE | `_harvester` | `harvester` (no zero-check) |
| SubLoop | `pause()` / `unpause()` | GUARDIAN_ROLE | none | `_paused` |
| Harvester | `addVault()` | DEFAULT_ADMIN_ROLE | `vault` | `vaults[]` (append-only; no dedup, no removal) |
| CollateralVault / SubLoop | `upgradeTo()` / `upgradeToAndCall()` | UPGRADER_ROLE | `newImplementation`, `data` | implementation slot |
| all four | `grantRole()` / `revokeRole()` | DEFAULT_ADMIN_ROLE | `role`, `account` | role members |

There is no admin function that moves user funds, force-unwinds a live position, or pauses
without the guardian role. An earlier `adminUnwind()` did the first two; it was removed.

---

## Initialization

| Contract | Function | Guard | Notes |
|----------|----------|-------|-------|
| CollateralVault | `initialize(name, symbol, collateral, pool, yieldSource, swapper, hollar, synthetic, collateralAToken, hollarDebtToken, synthLtBps, tvlCap, admin)` | `initializer` | Zero-checks only `_collateral`, `_pool`, `_admin`. Grants DEFAULT_ADMIN / ADMIN / UPGRADER / GUARDIAN to `_admin`. `compoundSlippageBps` defaults to 0. |
| SubLoop | `initialize(pool, hollar, prime, primeAToken, targetHf, deLeverTrigger, admin)` | `initializer` | No zero-checks. Sets `deployHfFloor = targetHf`, `harvestThreshold = 1e15`. Leaves `harvester`, `deployTranche`, `unwindTranche`, and all route ids at 0. |
| SyntheticToken | `constructor(name, symbol, admin)` | n/a | Zero-checks `admin`. No `MINTER_ROLE` granted at construction. |
| Harvester | `constructor(subLoop, prime, admin)` | n/a | Zero-checks all three. `subLoop` and `prime` are `immutable`. |

Both proxied implementations call `_disableInitializers()` in their constructors.
