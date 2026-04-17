# GIGAHDX on Lark 1 — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration, deployed and activated on the **Lark 1 test chain**.

- **RPC:** https://1.lark.hydration.cloud
- **WS:** wss://1.lark.hydration.cloud
- **chainId:** `222222`
- **Market ID:** `GIGAHDX`
- **ProviderId:** `22222269`

Machine-readable version: `GIGAHDX-LARK1-ADDRESSES.json`.

## Core pool contracts

| Contract | Address |
|---|---|
| Pool (entrypoint for supply/borrow/repay/withdraw) | `0x3d2e0116373610dD215d86080Ca79f417311F014` |
| PoolAddressesProvider | `0x2C481c22898d69AA9f27C55Ef281166371850E5F` |
| PoolConfigurator | `0x0C3183fC22b6655901CA914d8e2bB3305eC56Cfd` |
| ACLManager | `0x808F1bCF661581b727d39e315b843C5de3c5bF43` |
| AaveOracle | `0x1FB53E8B9494aFd71A3b81db29E8B89052F0edC3` |
| PoolDataProvider | `0x5EA812B9FfE4fFD426f77F9533218266365106ad` |
| PoolAddressesProviderRegistry | `0x843bFAa1Ae111e1919e6813C81020b45bF3D95fD` |
| Treasury | `0xaa372cE2D8760c6d8a4ad3E1941453BC7CFe1eeE` |
| IncentivesProxy | `0xfe14B6590ADD2f36837b3b4a3dA25B1AE64d9c1A` |

All admin roles on GIGAHDX are held by Hydration governance: `0xaa7e0000000000000000000000000000000aa7e0`.

## Reserves

### stHDX (collateral-only)

| | Address |
|---|---|
| Underlying | `0x000000000000000000000000000000010000029e` (substrate asset **670**, 12 decimals) |
| **aToken (GIGAHDX)** | **`0x770D46b6d3A6A17235dc308EEfB89731c9d0A8DF`** (LockableAToken, substrate asset **67** aka GIGAHDX) |
| variableDebtToken | `0xaa678f3031fcC6CbA4C34A58E3eEE564f2B83Deb` |
| stableDebtToken | `0x7Dc362e7a8Fd940e6826c14745E3b9Ae6EBcacC9` |
| rateStrategy | `0x5b2754D223dDC3B260966aAA50E2Eb6A0e275dDb` |
| oracle source | `0x202df3eDac2775b857ee2f61A3569731E53eC713` (USDOracleAdapter) |

**Risk:** LTV 40%, LT 70%, LB 8%, RF 20%, supplyCap 500M, borrowCap 0. Borrow disabled. Collateral-only.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | `0x531a654d1696ED52e7275A8cede955E82620f99a` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **`0xaA08D0b7A88844bba35c21d4faaB3eE51263B490`** — also the **HOLLAR facilitator** (1M bucket capacity) |
| variableDebtToken | `0xB78AF9b0E8eBC9709552C6fE93115498ce5A4c77` |
| stableDebtToken | `0x8E288bf34F42Fdf823660230719BdeC6483F71Da` (unused) |
| rateStrategy | `0x4094782515945AC1b41D515EF77358D8DA516645` (4.5% fixed APY) |
| oracle source | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` (GhoOracle, $1 fixed) |
| ZeroDiscountRateStrategy (cross-ref on varDebt) | `0x33A7C640140FEBafEcC9801AF723A0C14420eEd7` |

**Risk:** LTV 0%, LT 0%, LB 0%, RF 0%. No collateral value. Borrow enabled.

## Implementation contracts (for debugging / ABI loading)

| | Address |
|---|---|
| LockableAToken impl | `0x5F7daCEeA2939eC1EEA92F16Ec80aDBd8BCA6c84` |
| GhoAToken impl | `0x834CAcbcD3D00cC08f3D206d4e1D06B9c8e7baF1` |
| GhoVariableDebtToken impl | `0xB708dCcca5F8D7d8C1eC9EaEEB9eFE19e096903e` |
| GhoStableDebtToken impl | `0x67dD42576D32F128dE8CEDC24648a31bA16F2C09` |
| AToken impl (unused) | `0x3f4599Db4B3bFe6A7f07AfA897eA0491d1575A16` |
| StableDebtToken impl | `0x37643158Be7942b10C061051082e9bFEDc4Dec03` |
| VariableDebtToken impl | `0x46A41C0Fef36830B5708e7DC7df6C8922f04fbab` |

## Notes for frontend testing

- **Two reserves are live**: call `Pool.getReservesList()` to confirm.
- **To supply stHDX**: user must have a positive substrate balance of asset 670. The EVM `approve` + `Pool.supply(stHDX_underlying, amount, ...)` flow works, but reads `stHDX.decimals()` via the substrate-dispatch ERC20 precompile.
- **GIGAHDX aToken** is registered as substrate asset 67 with `AccountKey20` location pointing to `0x770D46b6d3A6A17235dc308EEfB89731c9d0A8DF`. Substrate-side balance transfers of GIGAHDX go through this address.
- **HOLLAR reserve is borrow-only** — can't be used as collateral, only minted when a user borrows. Repayment burns.
- **Price oracle caveat**: `AaveOracle.getAssetPrice(stHDX_underlying)` **reverts** on lark 1 because the upstream substrate oracle feeds aren't populated. `getAssetPrice(HOLLAR)` returns $1 fine. Until stHDX price works, `supply()` / `borrow()` will revert on the collateral-price read. Flag this to the runtime/oracle team if blocking your tests.
- **LockableAToken transfers**: `transfer` on the GIGAHDX aToken calls the `0x0806` LockManager precompile to check voting locks. If the user has no voting locks, transfer proceeds normally.

## Existing mainnet addresses reused

| | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| stHDX USDOracleAdapter | `0x202df3eDac2775b857ee2f61A3569731E53eC713` |
| Hydration governance (EVM-mapped) | `0xaa7e0000000000000000000000000000000aa7e0` |

## ABIs

ABIs for all GIGAHDX contracts are in `deployments/hydration/*-GIGAHDX.json` (hardhat-deploy format). Each file has `{address, abi}`.

Example contracts (ethers.js):

```typescript
import { ethers } from "ethers";
import PoolArtifact from "./deployments/hydration/Pool-Proxy-GIGAHDX.json";

const provider = new ethers.providers.JsonRpcProvider("https://1.lark.hydration.cloud");
const pool = new ethers.Contract(
  "0x3d2e0116373610dD215d86080Ca79f417311F014",
  PoolArtifact.abi,
  provider
);
const reserves = await pool.getReservesList(); // [stHDX underlying, HOLLAR underlying]
```
