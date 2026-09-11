# Propeller Mainnet Handover

> Companion to `propeller-vault/DEPLOYMENT.md` (the runbook) and
> `propeller-vault/deployments/` (the address registry).
> Modelled on `HDCL-MAINNET-HANDOVER.md`, whose "what went wrong" section saved the
> HDCL mainnet launch from repeating four separate lark mistakes.

**Read § "What went wrong on lark-4" before touching mainnet.** Everything in it cost real
time or a wasted referendum, and every item is repeatable.

---

## Components

| Component | Upgradeable | Where |
|---|---|---|
| `CollateralVault` (one per collateral: pETH, ptBTC) | UUPS | `propeller-vault/src/CollateralVault.sol` |
| `SubLoop` (ONE shared instance across all collaterals) | UUPS | `propeller-vault/src/SubLoop.sol` |
| `SyntheticToken` (psHOLLAR) | **No** | `propeller-vault/src/SyntheticToken.sol` |
| `Harvester` | **No** | `propeller-vault/src/Harvester.sol` |
| `HydraAugustus` (REQ-SWAP) | separate repo | `../aave-debt-swap` |
| `looper` keeper | Docker Swarm | `propeller-vault/looper/` |

The two non-upgradeable contracts are the ones to get right first time. A defect in either is
fixed only by redeploy + a governance rewire (`setHarvester` / `grantRole(MINTER_ROLE)`).

---

## Correct phase ordering

```
1. Deploy HydraAugustus            (../aave-debt-swap)      → SWAPPER
2. DeploySynth                                              → SYNTH
3. DeployMain                      (needs SYNTH, SWAPPER)   → SUBLOOP, VAULT_ETH, HARVESTER, IMPL
4. DeployVaultTBTC                 (needs IMPL)             → VAULT_TBTC
5. Referendum 1: list-reserve      (substrate register → initReserves)
6. Referendum 2: configure         (LTV/LT/borrowing/supply-cap/oracle)
7. Referendum 3: wire              (roles, registry, tranches, route, harvester, slippage, swapper, guardian)
8. verify-readiness.ts             ← GATE. Do not continue past a red row.
9. Seed deposit
10. pokeBorrow ramp                ← REQUIRED before anyone can redeem
11. Start the looper
12. Update deployments/ + re-run verify-readiness
```

Steps 5-7 are separate referenda because `initReserves` alone is ~58e9 refTime and a combined
`batchAll` trips `scheduler.PermanentlyOverweight`.

---

## What went wrong on lark-4 — and how to avoid it

### 1. Chased a circuit-breaker red herring (cost: 2 wasted referenda, ~a day)

`SubLoop.deposit` reverted `DcaDispatch.DispatchFailed`. The failure was **amount-dependent** —
a 4,500-HOLLAR sell failed, 2,250 succeeded — which pointed at HydraDX's `circuitBreaker`
per-block net-trade-volume limit. Two referenda were spent on it: **#371 failed** (tried to set
>100%), **#372 set 100%**.

It was the wrong diagnosis. The real error was `router.TradingLimitReached` raised by the
**router's own min-out check**, not the circuit breaker — the two surface similarly.

**Avoid:** decode the *module* error, not just the name. `router.TradingLimitReached` and
`circuitBreaker.TokenOutflowLimitReached` are different pallets. Scan the block's events for
the emitting pallet index before proposing a fix. The #372 change is harmless but unnecessary —
revert it when tidying.

### 2. The actual fix was slippage, not limits (ref #373)

Pool-143's HOLLAR→PRIME rate sits **~1.1% off oracle-fair**. `_fundDeploy` sizes its min-out
from the AaveOracle, so at `dcaSlippagePpm = 1%` the router could never fill.
`configureDca(222, 43, 1043, 143, 80000)` — 8% — unblocked it.

**This is a live risk parameter, not a tuning detail.** It is the slippage bound on two
*permissionless* entrypoints (`pokeBorrow`, `pokeRepay`), so 8% is the width of the sandwich a
caller could theoretically arrange. Before mainnet: measure pool-143's actual deviation, set
the tightest value that fills, and write down the intended tightening path as depth improves.

### 3. Diagnosed an "intra-tx EVM visibility" runtime bug that did not exist (cost: ~half a day)

The first theory was that `SubLoop.deposit`'s `transferFrom` of HOLLAR was not visible to the
`0x0401` dispatch precompile within the same transaction. A `DispatchProbe` contract doing
`transferFrom` + `router.sell` in one call returned `sellOk = true`, refuting it.

**Avoid:** when a same-transaction interaction is suspected, write the two-line probe *first*.
It cost minutes and would have skipped both this and lesson 1.

### 4. Redeeming before ramping orphaned a request (cost: a stuck request #0)

PRIME is listed in **isolation mode**, so a plain `supply` never auto-enables it as collateral —
only `pokeBorrow`'s explicit `setUserUseReserveAsCollateral` does. Until that runs the loop
reports `totalEquity() == 0`, and `requestUnwind` recorded a **zero** unwind target while the
vault escrowed shares and enqueued a real `debtShare`. The request could only ever settle by
accident, out of another unwind's freed HOLLAR.

**Fixed in the contracts:** `requestRedeem` now reverts `NoLoopEquity` in that state.
**Still an operational rule:** ramp before announcing, and assert `totalEquity() > 0` in the
readiness gate (it is check H).

### 5. A fresh chain needs `evmAccounts.bindEvmAddress()` (cost: ~an hour)

An unbound depositor EVM address makes the dispatch precompile read an empty account. Bind
every address that will transact before testing.

### 6. `@polkadot/api` was listed but not installed in `money-market` (cost: a blocked wiring run)

It was present in `aave-debt-swap/node_modules` but not here. Run `npm install` in the repo
root before the wiring step. (It resolves today — keep it that way.)

### 7. The mainnet proposal builder silently drifted from the contracts (found 2026-08-07)

`tasks/proposals/propeller.ts` — the *mainnet-shaped* path — had rotted while all real work
went through `scripts/propeller-wire-lark.mjs`:

- `configureDca` encoded with **6 arguments** against a 5-argument function → selector
  mismatch → the call would have reverted inside the batch
- granted `KEEPER_ROLE`, **removed from the contracts** in `1e1e5ac` — `grantRole` with an
  unknown role id succeeds silently and wires nothing
- lark-2 HDCL route ids (`222/550/55/10055`) instead of PRIME (`222/43/1043/143`)
- no `setHarvester` → carry would have been claimable by any caller
- no `setCompoundSlippageBps` → every compound would revert
- no `GUARDIAN_ROLE` delegation

**Avoid:** the lark script and the mainnet task must not diverge. Either generate both from one
source, or run the mainnet task in dry-run against every lark deploy so it stays exercised.
Nothing catches an unexercised code path except exercising it.

### 8. Wiring was applied per-vault inconsistently (found 2026-08-07 by `verify-readiness`)

The lark-4 wiring set `compoundSlippageBps = 100` on the **pETH** vault and never set it on
**ptBTC**, which therefore sits at 0 — meaning every harvest compound into ptBTC reverts. It
went unnoticed for a week because nothing read the state back.

**Avoid:** the proposal builder now loops over `PROPELLER_VAULTS` so per-vault settings cannot
be applied to one and forgotten on another, and `verify-readiness` checks every vault
independently. Run it after *every* governance change, not just the first.

### 9. Mock fidelity hid a real bug (found 2026-08-07)

`MockPool` auto-enabled PRIME as collateral on first supply. Real Aave does not for an
isolation-mode reserve — which is precisely why `SubLoop.pokeBorrow` opens with an explicit
enable. That divergence is what let lesson 4's orphan bug through the entire test suite.

**Avoid:** when a contract contains a workaround for external behaviour, the mock must model
the behaviour being worked around, or the workaround's absence is untestable. `MockPool` now
models isolation mode. `MockPool` still **accrues no interest** and `MockDispatch` still
defaults to **zero swap fee** — both remain known blind spots (see `AUDIT.md`).

### 10. `setYieldSource` is unreachable once a vault is funded (found 2026-08-07)

`DEAD_SHARES` stay locked in `totalSupply` forever, so `requestRedeem` always leaves the dead
shares' proportional loop slice behind and `loopShares` never returns to 0. The guard is
therefore satisfiable only before the first deposit.

**Not a bug — but plan around it.** There is no in-place yield-source migration. To change a
live vault's source, deploy a new vault and let holders migrate through the redemption queue.
Get the source right at deploy time.

---

## Risk parameters that need a decision before mainnet

| Parameter | lark-4 value | Question |
|---|---|---|
| `dcaSlippagePpm` | 80000 (8%) | What is mainnet pool-143's real deviation? Set the tightest value that fills |
| `deployTranche` / `unwindTranche` | 5000 / 5000 | Sized against mainnet depth, not lark's |
| `tvlCap` | 1e24 | Launch cap should be far lower and raised on evidence |
| `targetHf` | 1.05 | ~20× leverage on the loop. Deliberate? |
| `deLeverTrigger` | 1.10 | Above `targetHf`, so it is a ceiling not a floor — the operative gate in `deLever()` is `hf < targetHf` |
| `compoundSlippageBps` | 100 | Per-vault. Set it on **every** vault |
| Synthetic LT | 9800 | Read **live**; changing it later changes the floor for every existing position |

---

## Known limitations carried into mainnet

- **No fork tests.** The Aave money market, the AaveOracle, the `0x0401` router precompile and
  HydraAugustus are all exercised only against mocks.
- **No external audit.** The in-repo report is AI-assisted and says so in its own footer.
- **All five privileged roles sit on one address** at `initialize`, with no on-chain timelock.
  Batch 3 delegates `GUARDIAN_ROLE` to the technical committee; nothing else is separated.
- **The de-lever spiral is inoperable below HF 1.02** — `pokeRepay`'s sell gate never opens, so
  a sharp PRIME drawdown freezes both de-levering and redemption funding until price recovers
  or Aave liquidates the loop. Arguably the designed risk split (the loop is the sink; user
  principal is floored by the synthetic and un-liquidatable), but it is undocumented as a
  deliberate choice.
- **A redeemer can be settled marginally short.** `_retireExhaustedHead` snaps a head request's
  `debtShare` down to what the spiral actually realized once the source is exhausted, so the
  FIFO queue cannot jam. Measured at 1.3e-11 relative with a frictionless mock; real slippage
  widens it. Collateral is released strictly proportionally, so short settlement means
  proportionally less collateral, never someone else's.
- **`SyntheticToken` transfers are unrestricted.** It is a real Aave reserve at LT 9800 with no
  supply cap; only `MINTER_ROLE` custody keeps it contained. The soulbinding note at
  `SyntheticToken.sol:50` was deferred "before audit" and never revisited.
- **REQ-DISCOUNT is unimplemented.** Real net carry is ~8.6% (`maxLtv · loopLeverage · spread`).
  Any higher headline number assumes a redemption-discount mechanism that does not exist.
- **PRIME mirror oracle** is still owned by the looper hot key on lark. Mainnet needs governance
  ownership with the bot behind an updater role.
