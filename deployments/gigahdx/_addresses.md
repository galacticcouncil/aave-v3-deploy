# GIGAHDX on Lark 2 — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration, deployed and activated on the **Lark 2 test chain**.

- **RPC:** https://node0.lark.hydration.cloud
- **WS:** wss://node0.lark.hydration.cloud
- **chainId:** `222222`
- **Market ID:** `GIGAHDX`
- **ProviderId:** `22222269`

Machine-readable version: `deployments/gigahdx/_addresses.json`.

## Core pool contracts

| Contract | Address |
|---|---|
| Pool (entrypoint for supply/borrow/repay/withdraw) | `0x2Ce2CfFF743CdB6637F4B5D351937A541B8c8923` |
| PoolAddressesProvider | `0x3C7D7b74bB625736b93d859e332F06Df64635973` |
| PoolConfigurator | `0x155900567996f761cc9F7332628Bfc6E4B64Cb33` |
| ACLManager | `0xF6677702a2B7E2076d9Da3D1d69b825726a78675` |
| AaveOracle | `0xcE5BB65E09f69C038b1f1EA447EeDBf1c365AFCC` |
| PoolDataProvider | `0xAA3d202CDA57B86c68D4A0EA5a6AFC83297677a1` |
| PoolAddressesProviderRegistry | `0xF62e632f59247e5A52F534D5d660b36b3E47Ec0D` |
| Treasury | `0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9` |
| IncentivesProxy | `0x562c0288FBaF59d798Bb54aa189805d2AaEA3D17` |
| EmissionManager | `0xEb079146887C206360DEacd28D8A5a507918CF00` |

All admin roles on GIGAHDX are held by Hydration governance: `0xaa7e0000000000000000000000000000000aa7e0`.

## Reserves

### stHDX (collateral-only)

| | Address |
|---|---|
| Underlying | `0x000000000000000000000000000000010000029e` (substrate asset **670**, 12 decimals) |
| **aToken (GIGAHDX)** | **`0x0000000000000000000000000000000000000000`** (LockableAToken, substrate asset **67**) |
| variableDebtToken | `0x0000000000000000000000000000000000000000` |
| stableDebtToken | `0x0000000000000000000000000000000000000000` (unused) |
| rateStrategy | `0x0000000000000000000000000000000000000000` |
| oracle source | `undefined` (FixedPriceOracle @ $0.025) |

**Risk:** LTV 40%, LT 70%, LB 8%, RF 20%, supply-only. Borrow disabled.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | `0x531a654d1696ED52e7275A8cede955E82620f99a` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **`0x0000000000000000000000000000000000000000`** — also the **HOLLAR facilitator** (1M bucket capacity) |
| variableDebtToken | `0x0000000000000000000000000000000000000000` |
| stableDebtToken | `0x0000000000000000000000000000000000000000` (unused) |
| rateStrategy | `0x0000000000000000000000000000000000000000` (4.5% fixed APY) |
| oracle source | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (GhoOracle, $1 fixed) |

**Risk:** no collateral value, borrow-only. 1M HOLLAR facilitator bucket on HOLLAR token.

## Implementation contracts

| | Address |
|---|---|
| LockableAToken impl | `0xD7150D01C40192Cf7B6d1ae7817E566C56834f5A` |
| GhoAToken impl | `0x8abfc4EE32AF8F4B49195114A881e1f9dAe50c32` |
| GhoVariableDebtToken impl | `0xE697CEE79932C0BFa1a929F3b08a8570dc3ed879` |
| GhoStableDebtToken impl | `0xf8C642DAfbF606610aBAFe2F2100db91Bd1CC799` |
| GhoInterestRateStrategy | `0x6033f11603e26B7B5a2384cD83F81Ab4C0b1220F` |
| Pool Implementation | `0x644d0341e0D00DfB9e6224b133B916A6e1F73c44` |
| PoolConfigurator Implementation | `0x1A680Db038939251828DB715D4d22c991f3ADF32` |
| AToken (unused) | `0x7ff2800a710AEAF60aFdc83Ce7f18CafA0E78e39` |
| StableDebtToken (unused) | `0x691EFE7Cd088eB3b958ea7Dbe3dbF45c3DA77496` |
| VariableDebtToken (unused) | `0x9055F1dE9D4f66647357Fa6Fc9dC097f7f5cD2d9` |

## Existing mainnet addresses reused

| | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| Hydration governance (EVM-mapped) | `0xaa7e0000000000000000000000000000000aa7e0` |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` |
