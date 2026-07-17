# BIL on Hydration — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration. BIL (Brazilian Invoice Loans, the
yield-bearing vault share over Decentral Protocol positions) is the collateral
asset; HOLLAR is borrow-only via the GhoAToken facilitator.

- **RPC:** https://node0.lark.hydration.cloud
- **WS:** wss://node0.lark.hydration.cloud
- **chainId:** `222222`
- **Market ID:** `BIL`
- **ProviderId:** `22222255`

Machine-readable version: `deployments/bil/_addresses.json`.

## Core pool contracts

| Contract | Address |
|---|---|
| Pool (entrypoint for supply/borrow/repay/withdraw) | `0xd10b84Ee54dc5B81366b56bABBF4D32303629835` |
| PoolAddressesProvider | `0x08D80c63A87746487d673b488FF40386c68cE192` |
| PoolConfigurator | `0x233379cCad565122d93eBf2C76e793d0403fDE94` |
| ACLManager | `0x04Ed8a7cF648f16BBCf54CF2EB75a40B0d4aA142` |
| AaveOracle | `0xbBcd40c0b9Ee8Aa43F1a9519c05d2770F967CcC5` |
| PoolDataProvider | `0x653DFc382b74E7399dae06DC4d07202E28b5990B` |
| PoolAddressesProviderRegistry | `0xEdEcE54767182abc1b04FE699A96CF7e97a3CcF2` |
| Treasury | `0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9` |
| IncentivesProxy | `0x8Ec25A204668226943254DCd4af1697bfB7EC346` |
| EmissionManager | `0x4d680C4A9C7b71e82Ba98B57f891DE7987A79971` |

All admin roles on BIL are held by Hydration governance: `0xaa7e0000000000000000000000000000000aa7e0`.

## BIL Vault stack

The vault is what gives BIL its yield — it wraps Decentral Protocol NFT lending
positions and exposes ERC-4626 (deposit) + ERC-7540 (async redeem) on top.

| Contract | Address |
|---|---|
| BILVault (proxy) | `undefined` |
| BILVault impl | `undefined` |
| QueueLib (delegate-called library) | `undefined` |
| BILOracle (Chainlink-V3 reader of `vault.exchangeRate()`) | `undefined` |
| BILOracleAdapter (IEACAggregatorProxy on top of BILOracle, used by Aave) | `0x52f934a10dB0Ef0aef953CF265Ed8EEe98e3689e` |
| BILDepositZap (atomic HOLLAR→BIL→aBIL helper) | `0xFF14a4Bf1Fe038D23b68d738B81cF900FD6E9D8B` |

## Reserves

### BIL (collateral-only)

| | Address |
|---|---|
| Underlying | `0x0000000000000000000000000000000100000226` (substrate asset **550**, 18 decimals, vault token) |
| **aToken (aBIL)** | **`0x0000000000000000000000000000000000000000`** (standard AToken, substrate asset **55**) |
| variableDebtToken | `0x0000000000000000000000000000000000000000` |
| stableDebtToken | `0x0000000000000000000000000000000000000000` (unused) |
| rateStrategy | `0x0000000000000000000000000000000000000000` (Stables curve) |
| oracle source | `0x52f934a10dB0Ef0aef953CF265Ed8EEe98e3689e` (BILOracleAdapter — reads vault.exchangeRate()) |

**Risk:** LTV 80%, LT 85%, LB 7%, RF 20%, supply-only, 3M supply cap. Borrow disabled.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | `0x531a654d1696ED52e7275A8cede955E82620f99a` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **`0x0000000000000000000000000000000000000000`** — also the **HOLLAR facilitator** (1M bucket capacity) |
| variableDebtToken | `0x0000000000000000000000000000000000000000` |
| stableDebtToken | `0x0000000000000000000000000000000000000000` (unused) |
| rateStrategy | `0x0000000000000000000000000000000000000000` (10% fixed APY) |
| oracle source | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (GhoOracle, $1 fixed) |

**Risk:** no collateral value, borrow-only. 1M HOLLAR facilitator bucket on HOLLAR token.

## Implementation contracts

| | Address |
|---|---|
| AToken impl | `0xd1519b76c541B920737d2f97ddF7b3E7015b66A1` |
| DelegationAwareAToken impl | `0x0C4C8Fa2D64a727FE8930B994c697ec7fb1DdCF1` |
| StableDebtToken impl | `0x23c424780bC3259b94e90CdEf7feF7B84931Ea95` |
| VariableDebtToken impl | `0x312a018F3889B9372266F38062cCa8f0E1a215a9` |
| GhoAToken impl | `0xB9947CaCebD0F23de3b59c369cD710137739Cd83` |
| GhoVariableDebtToken impl | `0xe08E03f3A1F02b758eefD64a85cD037dA04Fb09B` |
| GhoStableDebtToken impl | `0x2D7D76b1B443464e5bC699303438cDbaee708bF2` |
| GhoInterestRateStrategy | `0x75C28DbE7b035FC60ca92ec92676E0F41b7bd26B` |
| Pool Implementation | `0x9f4c83343Cd72d48d275B8D457aDd91bCb51bcd7` |
| PoolConfigurator Implementation | `0xAC611e17f191312003E9b13483Ddf1384cc6f1ef` |

## Existing mainnet addresses reused

| | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| Hydration governance (EVM-mapped) | `0xaa7e0000000000000000000000000000000aa7e0` |
| ZeroDiscountRateStrategy | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` |
