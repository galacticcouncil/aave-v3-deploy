# GIGAHDX on Lark 2 — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration, deployed and activated on the **Lark 2 test chain**.

- **RPC:** https://2.lark.hydration.cloud
- **WS:** wss://2.lark.hydration.cloud
- **chainId:** `222222`
- **Market ID:** `GIGAHDX`
- **ProviderId:** `22222269`

Machine-readable version: `GIGAHDX-LARK2-ADDRESSES.json`.

## Core pool contracts

| Contract | Address |
|---|---|
| Pool (entrypoint for supply/borrow/repay/withdraw) | `0xb952AE92cC4D8D703d2d71Ab541baB34c94b944A` |
| PoolAddressesProvider | `0x9574d4AfAB726f059DB7149FFF7169cB6E0D06Bf` |
| PoolConfigurator | `0xD03b3f4412fE10A2692a18F1240ff414044E141E` |
| ACLManager | `0x738570029129cD326598f80d2325e06C8c7B90Bc` |
| AaveOracle | `0x1f14A240f5Aa8eDD4C5f375B82b3B1d836eF4983` |
| PoolDataProvider | `0x764133FB176607C80BE2463Ec0711D5197f4566a` |
| PoolAddressesProviderRegistry | `0xe36D8630E2C87F0389ffd2DdE39470D9946d04d3` |
| Treasury | `0xaFc199f2d2c0E23b909eBbdB41e8FC4507342dd4` |
| IncentivesProxy | `0xDc47FdD8a4525FC088964979EEe839356554ea34` |
| EmissionManager | `0x06A4D5f270D64b910378DBF9d484A10512a57C44` |

All admin roles on GIGAHDX are held by Hydration governance: `0xaa7e0000000000000000000000000000000aa7e0`.

## Reserves

### stHDX (collateral-only)

| | Address |
|---|---|
| Underlying | `0x000000000000000000000000000000010000029e` (substrate asset **670**, 12 decimals) |
| **aToken (GIGAHDX)** | **`0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661`** (LockableAToken, substrate asset **67**) |
| variableDebtToken | `0x9b282543A9AB63C5487F8949f5f50E62ac22E9e3` |
| stableDebtToken | `0x818eBB9498a5f0f10287C994F9c5cD6d8c79C9D2` (unused) |
| rateStrategy | `0x867Fe3Ba9e80c436a3716c2d9BFfaBdC05a4867D` |
| oracle source | `0x4605D2c76B3611FA467CAEeeb555D6045CbD8c6C` (FixedPriceOracle @ $0.025) |

**Risk:** LTV 40%, LT 70%, LB 8%, RF 20%, supply-only. Borrow disabled.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | `0x531a654d1696ED52e7275A8cede955E82620f99a` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **`0x4eDd0d8cf03aC94F9c6D3a5424023498b9ac250c`** — also the **HOLLAR facilitator** (1M bucket capacity) |
| variableDebtToken | `0x8Ba27f3761341D622574a70abD1EAe75845b5045` |
| stableDebtToken | `0x013Ab4D6136034409718593034E91e8730A3896A` (unused) |
| rateStrategy | `0x1FB53E8B9494aFd71A3b81db29E8B89052F0edC3` (4.5% fixed APY) |
| oracle source | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (GhoOracle, $1 fixed) |

**Risk:** no collateral value, borrow-only. 1M HOLLAR facilitator bucket on HOLLAR token.

## Implementation contracts

| | Address |
|---|---|
| LockableAToken impl | `0xb6FFC1d08496C884f822472988f3aFc035B1C761` |
| GhoAToken impl | `0x48B3357508A46c2e15D4241c6A815764eC71b9aA` |
| GhoVariableDebtToken impl | `0xc5f46C6E699E894faD98Fcd8E403BDE29463d6F8` |
| GhoStableDebtToken impl | `0x808F1bCF661581b727d39e315b843C5de3c5bF43` |
| GhoInterestRateStrategy | `0x1FB53E8B9494aFd71A3b81db29E8B89052F0edC3` |
| Pool Implementation | `0x7cEB7eB086551C9A09b954FaCb58AD57961E298C` |
| PoolConfigurator Implementation | `0x1d7B4987f53dBF4f35C54E587b74b34C500844Df` |
| AToken (unused) | `0x6D502d4F24eD1dCd37123d893E170F46f6A0F24F` |
| StableDebtToken (unused) | `0x2d69e3D829538ca40C9eE00bcCA62DcDf9CE1B5C` |
| VariableDebtToken (unused) | `0xDB0F10e9d6aD1ff8A04df40903b76B4a3cF1CA4E` |

## Existing mainnet addresses reused

| | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| Hydration governance (EVM-mapped) | `0xaa7e0000000000000000000000000000000aa7e0` |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` |
