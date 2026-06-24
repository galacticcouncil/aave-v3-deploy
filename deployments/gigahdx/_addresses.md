# GIGAHDX on Hydration — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration. stHDX collateral-only, HOLLAR borrow-only via the GhoAToken facilitator.

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
| **aToken (GIGAHDX)** | **`0x6b9aC524ec8f08C49ec80176B138D16EB461c3D8`** (LockableAToken, substrate asset **67**) |
| variableDebtToken | `0x85B849E2B235a1961d9B44336BD3FefCff3898a3` |
| stableDebtToken | `0x5575F07b559A8CB80eEd4c085C21c0F75fEBc250` (unused) |
| rateStrategy | `0x3B82eFebF099a3E262F894f8872028FD433487a6` |
| oracle source | `0x645C0011595cEa8bA5db838bCcA0A5F204dD4883` (USDOracleAdapter — Omnipool EMA, ~$0.0039) |

**Risk:** LTV 40%, LT 70%, LB 8%, RF 20%, supply-only. Borrow disabled.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | `0x531a654d1696ED52e7275A8cede955E82620f99a` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **`0x116D7Bb8E4e2a4C932B4d36c115D4122dc360462`** — also the **HOLLAR facilitator** (222,222 bucket capacity) |
| variableDebtToken | `0x6F731562cBf2c0dA50a10E5aC922b95b42204863` |
| stableDebtToken | `0x7dEdEa1E7C60c192014d553C4B2a04FeF323fe88` (unused) |
| rateStrategy | `0x6033f11603e26B7B5a2384cD83F81Ab4C0b1220F` (9% fixed APY) |
| oracle source | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (GhoOracle, $1 fixed) |

**Risk:** no collateral value, borrow-only. 222,222 HOLLAR facilitator bucket on HOLLAR token.

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
