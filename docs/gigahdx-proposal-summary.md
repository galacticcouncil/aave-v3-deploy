# GIGAHDX Launch — Deployment & Proposal Summary

**What it is:** A second, standalone Aave V3 pool on Hydration for the GigaHDX
staking product. Two one-directional reserves:

- **stHDX** (asset 670) — collateral only, uses a `LockableAToken`
- **HOLLAR** (asset 222) — borrow only, via the GHO facilitator pattern

---

## Part 1 — Contracts deployed (before the proposal, by the deployer EOA)

**Core pool** (`deploy --tags market`):
`PoolAddressesProvider-GIGAHDX` (provider id `22222269`), `Pool-Proxy`,
`PoolConfigurator-Proxy`, `ACLManager`, `AaveOracle`, `PoolDataProvider`,
Treasury, Incentives, reserve rate strategies, and the standard Aave token impls.

**stHDX side:**
- `LockableAToken-GIGAHDX` — aToken impl with vote-lock enforcement (via the
  `0x0806` LockManager precompile)
- `STHDX-USDOracleAdapter` — stHDX price = stHDX/HDX (gigahdxs source) × HDX/USD
  (**Omnipool EMA, Day period**)

**HOLLAR side** (per-pool GHO impls, from the gho-core/hollar repo — each bakes
the GIGAHDX pool address in as an immutable, so they are pool-specific):
- `GhoAToken-GIGAHDX`, `GhoVariableDebtToken-GIGAHDX`,
  `GhoStableDebtToken-GIGAHDX`, `GhoInterestRateStrategy-GIGAHDX`
- *HOLLAR token (`0x531a654d1696ED52e7275A8cede955E82620f99a`) already exists —
  NOT deployed, only referenced.*

Then all admin roles (DEFAULT_ADMIN / POOL_ADMIN / RISK_ADMIN / EMERGENCY_ADMIN +
ACLAdmin + ownership) are transferred to the Hydration governance precompile
`0xaa7e0000000000000000000000000000000aa7e0`.

---

## Part 2 — The governance proposal (one atomic `utility.batchAll`)

EVM calls run as the AaveManager (`0xaa7e…`) via
`dispatcher.dispatchAsAaveManager → evm.call`; substrate calls are direct.

```
[0]  assetRegistry.register(670 stHDX, ED 0)            ← registered FIRST (ERC20 precompile must be live before init)
[1]  AaveOracle.setAssetSources(stHDX → USDOracleAdapter)
[2]  PoolConfigurator.initReserves(stHDX, LockableAToken impl)
[3]  ReservesSetupHelper.configureReserves(stHDX risk params)
[4]  PoolConfigurator.initReserves(HOLLAR, GhoAToken impl)
[5]  PoolConfigurator.setReserveBorrowing(HOLLAR, true)
[6]  AaveOracle.setAssetSources(HOLLAR → GhoOracle = $1)
[7]  HOLLAR.addFacilitator(GhoAToken, "GIGAHDX", 222,222e18)
[8]  GhoAToken.setVariableDebtToken(...)
[9]  GhoAToken.updateGhoTreasury(...)
[10] GhoVariableDebt.setAToken(...)
[11] GhoVariableDebt.updateDiscountRateStrategy(ZeroDiscountRateStrategy)
[12] GhoVariableDebt.updateDiscountToken(HOLLAR)
[13] assetRegistry.register(67 GIGAHDX → stHDX aToken, ED 0)   ← GIGAHDX receipt asset
[14] gigaHdx.setPoolContract(Pool)                             ← runtime points staking adapter at this pool
[15] evmAccounts.approveContract(Pool)                         ← lets HOLLAR.transferFrom work in liquidations
```

**Why the ordering matters:** `register(670)` is call `[0]` so the stHDX ERC20
precompile is live before `initReserves(stHDX)` runs — otherwise the init reverts
and downstream proxy-address predictions shift, mis-wiring HOLLAR's facilitator.

---

## Part 3 — Key parameters

| Parameter | Value |
|---|---|
| stHDX LTV / Liq. Threshold / Liq. Bonus | 40% / 70% / 8% |
| Liquidation protocol fee | **0%** |
| Reserve factor | 20% |
| Supply cap | **0 (uncapped)** |
| Existential deposit (stHDX, GIGAHDX) | **0** |
| stHDX oracle | Omnipool EMA HDX/USD, **Day** period |
| HOLLAR facilitator bucket | **222,222 HOLLAR** |
| HOLLAR price | fixed $1 (GhoOracle) |

---

## Deployed addresses (0.lark test deployment)

> These are the **0.lark testnet** addresses. Mainnet addresses are recorded at
> launch and will differ. The stHDX aToken (`0x4eDd…`) and GhoAToken proxy
> (`0x25fA2B…`) are created by the proposal itself (calls [2] and [4]).

| Contract | Address |
|---|---|
| PoolAddressesProvider-GIGAHDX (provider id 22222269) | `0x9574d4AfAB726f059DB7149FFF7169cB6E0D06Bf` |
| Pool-Proxy-GIGAHDX | `0xb952AE92cC4D8D703d2d71Ab541baB34c94b944A` |
| PoolConfigurator-Proxy-GIGAHDX | `0xD03b3f4412fE10A2692a18F1240ff414044E141E` |
| ACLManager-GIGAHDX | `0x738570029129cD326598f80d2325e06C8c7B90Bc` |
| AaveOracle-GIGAHDX | `0x1f14A240f5Aa8eDD4C5f375B82b3B1d836eF4983` |
| LockableAToken-GIGAHDX (impl) | `0x867Fe3Ba9e80c436a3716c2d9BFfaBdC05a4867D` |
| STHDX-USDOracleAdapter | `0xb6FFC1d08496C884f822472988f3aFc035B1C761` |
| GhoAToken-GIGAHDX (impl) | `0xC44EB69093656401986e25AfAB04FA18cF9eAA90` |
| GhoVariableDebtToken-GIGAHDX (impl) | `0x1ce00629167d019cC8C86D91d18478DF474D7fE5` |
| GhoStableDebtToken-GIGAHDX (impl) | `0xF691B33a264f68F9333D2473a18f20c2262015f6` |
| GhoInterestRateStrategy-GIGAHDX | `0x93c307a4A2b05F4905E55cDA9d30E61F16348C8d` |
| stHDX aToken proxy *(created by proposal)* | `0x4eDd0d8cf03aC94F9c6D3a5424023498b9ac250c` |
| GhoAToken proxy *(created by proposal)* | `0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661` |
| HOLLAR (GhoToken, pre-existing) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| Governance (AaveManager precompile) | `0xaa7e0000000000000000000000000000000aa7e0` |
