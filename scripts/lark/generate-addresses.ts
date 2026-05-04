import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const deployments = path.join(__dirname, "..", "..", "deployments", "lark2");
  const artifacts: Record<string, string> = {};

  for (const f of fs.readdirSync(deployments)) {
    if (!f.endsWith(".json")) continue;
    const p = path.join(deployments, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf8"));
      if (j.address) artifacts[f.replace(".json", "")] = j.address;
    } catch {}
  }

  // Known per-market addresses from the GIGAHDX config
  const AAVE_MANAGER = "0xaa7e0000000000000000000000000000000aa7e0";
  const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
  const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";
  const STHDX_UNDERLYING = "0x000000000000000000000000000000010000029e";

  // Read live state
  const poolAddr = artifacts["Pool-Proxy-GIGAHDX"];
  const pool = await hre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16 id,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint128,uint128,uint128))"
    ],
    poolAddr
  );

  const stHdxData = await pool.getReserveData(STHDX_UNDERLYING);
  const hollarData = await pool.getReserveData(HOLLAR);

  const out = {
    name: "GIGAHDX on Hydration Lark 2",
    description: "Second Aave V3 money market instance on Hydration. stHDX collateral-only, HOLLAR borrow-only via GhoAToken facilitator. Deployed 2026-04-25.",
    network: {
      chainId: 222222,
      rpcUrl: "https://2.lark.hydration.cloud",
      wsUrl: "wss://2.lark.hydration.cloud",
      marketId: "GIGAHDX",
      providerId: 22222269,
    },
    core: {
      Pool: artifacts["Pool-Proxy-GIGAHDX"],
      PoolAddressesProvider: artifacts["PoolAddressesProvider-GIGAHDX"],
      PoolConfigurator: artifacts["PoolConfigurator-Proxy-GIGAHDX"],
      ACLManager: artifacts["ACLManager-GIGAHDX"],
      AaveOracle: artifacts["AaveOracle-GIGAHDX"],
      PoolDataProvider: artifacts["PoolDataProvider-GIGAHDX"],
      PoolAddressesProviderRegistry: artifacts["PoolAddressesProviderRegistry"],
      Treasury: artifacts["TreasuryProxy"],
      IncentivesProxy: artifacts["IncentivesProxy"],
      EmissionManager: artifacts["EmissionManager"],
    },
    admin: AAVE_MANAGER,
    reserves: {
      stHDX: {
        underlying: STHDX_UNDERLYING,
        substrateAssetId: 670,
        aToken_LockableAToken: stHdxData.aTokenAddress,
        variableDebtToken: stHdxData.variableDebtTokenAddress,
        stableDebtToken: stHdxData.stableDebtTokenAddress,
        interestRateStrategy: stHdxData.interestRateStrategyAddress,
        oracleSource_FixedPrice: artifacts["FixedPriceOracle-stHDX-GIGAHDX"],
        risk: "LTV 40%, LT 70%, LB 8%, RF 20%, supply-only"
      },
      HOLLAR: {
        underlying: HOLLAR,
        aToken_GhoAToken: hollarData.aTokenAddress,
        variableDebtToken: hollarData.variableDebtTokenAddress,
        stableDebtToken: hollarData.stableDebtTokenAddress,
        interestRateStrategy: hollarData.interestRateStrategyAddress,
        oracleSource_GhoOracle: GHO_ORACLE,
        risk: "no collateral value, borrow-only. 1M HOLLAR facilitator bucket on HOLLAR token."
      }
    },
    implementations: {
      LockableAToken: artifacts["LockableAToken-GIGAHDX"],
      GhoAToken: artifacts["GhoAToken-GIGAHDX"],
      GhoVariableDebtToken: artifacts["GhoVariableDebtToken-GIGAHDX"],
      GhoStableDebtToken: artifacts["GhoStableDebtToken-GIGAHDX"],
      GhoInterestRateStrategy: artifacts["GhoInterestRateStrategy-GIGAHDX"],
      Pool_Implementation: artifacts["Pool-Implementation"],
      PoolConfigurator_Implementation: artifacts["PoolConfigurator-Implementation"],
      AToken: artifacts["AToken-GIGAHDX"],
      StableDebtToken: artifacts["StableDebtToken-GIGAHDX"],
      VariableDebtToken: artifacts["VariableDebtToken-GIGAHDX"],
    },
    rateStrategies: {
      DOT: artifacts["ReserveStrategy-rateStrategyDOT"],
      StableOne: artifacts["ReserveStrategy-rateStrategyStableOne"],
      StableTwo: artifacts["ReserveStrategy-rateStrategyStableTwo"],
      VolatileOne: artifacts["ReserveStrategy-rateStrategyVolatileOne"],
    },
    existingMainnetAddresses: {
      HOLLAR_GhoToken: HOLLAR,
      GhoOracle: GHO_ORACLE,
      AaveManager: AAVE_MANAGER,
      ZeroDiscountRateStrategy: artifacts["ZeroDiscountRateStrategy"] ?? "0x33A7C640140FEBafEcC9801AF723A0C14420eEd7"
    }
  };

  const jsonPath = path.join(deployments, "_addresses.json");
  fs.writeFileSync(jsonPath, JSON.stringify(out, null, 2));
  console.log(`wrote ${jsonPath}`);

  // Markdown version
  const md = `# GIGAHDX on Lark 2 — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration, deployed and activated on the **Lark 2 test chain**.

- **RPC:** ${out.network.rpcUrl}
- **WS:** ${out.network.wsUrl}
- **chainId:** \`${out.network.chainId}\`
- **Market ID:** \`${out.network.marketId}\`
- **ProviderId:** \`${out.network.providerId}\`

Machine-readable version: \`deployments/lark2/_addresses.json\`.

## Core pool contracts

| Contract | Address |
|---|---|
| Pool (entrypoint for supply/borrow/repay/withdraw) | \`${out.core.Pool}\` |
| PoolAddressesProvider | \`${out.core.PoolAddressesProvider}\` |
| PoolConfigurator | \`${out.core.PoolConfigurator}\` |
| ACLManager | \`${out.core.ACLManager}\` |
| AaveOracle | \`${out.core.AaveOracle}\` |
| PoolDataProvider | \`${out.core.PoolDataProvider}\` |
| PoolAddressesProviderRegistry | \`${out.core.PoolAddressesProviderRegistry}\` |
| Treasury | \`${out.core.Treasury}\` |
| IncentivesProxy | \`${out.core.IncentivesProxy}\` |
| EmissionManager | \`${out.core.EmissionManager}\` |

All admin roles on GIGAHDX are held by Hydration governance: \`${out.admin}\`.

## Reserves

### stHDX (collateral-only)

| | Address |
|---|---|
| Underlying | \`${out.reserves.stHDX.underlying}\` (substrate asset **670**, 12 decimals) |
| **aToken (GIGAHDX)** | **\`${out.reserves.stHDX.aToken_LockableAToken}\`** (LockableAToken, substrate asset **67**) |
| variableDebtToken | \`${out.reserves.stHDX.variableDebtToken}\` |
| stableDebtToken | \`${out.reserves.stHDX.stableDebtToken}\` (unused) |
| rateStrategy | \`${out.reserves.stHDX.interestRateStrategy}\` |
| oracle source | \`${out.reserves.stHDX.oracleSource_FixedPrice}\` (FixedPriceOracle @ $0.025) |

**Risk:** ${out.reserves.stHDX.risk}. Borrow disabled.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | \`${out.reserves.HOLLAR.underlying}\` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **\`${out.reserves.HOLLAR.aToken_GhoAToken}\`** — also the **HOLLAR facilitator** (1M bucket capacity) |
| variableDebtToken | \`${out.reserves.HOLLAR.variableDebtToken}\` |
| stableDebtToken | \`${out.reserves.HOLLAR.stableDebtToken}\` (unused) |
| rateStrategy | \`${out.reserves.HOLLAR.interestRateStrategy}\` (4.5% fixed APY) |
| oracle source | \`${out.reserves.HOLLAR.oracleSource_GhoOracle}\` (GhoOracle, $1 fixed) |

**Risk:** ${out.reserves.HOLLAR.risk}

## Implementation contracts

| | Address |
|---|---|
| LockableAToken impl | \`${out.implementations.LockableAToken}\` |
| GhoAToken impl | \`${out.implementations.GhoAToken}\` |
| GhoVariableDebtToken impl | \`${out.implementations.GhoVariableDebtToken}\` |
| GhoStableDebtToken impl | \`${out.implementations.GhoStableDebtToken}\` |
| GhoInterestRateStrategy | \`${out.implementations.GhoInterestRateStrategy}\` |
| Pool Implementation | \`${out.implementations.Pool_Implementation}\` |
| PoolConfigurator Implementation | \`${out.implementations.PoolConfigurator_Implementation}\` |
| AToken (unused) | \`${out.implementations.AToken}\` |
| StableDebtToken (unused) | \`${out.implementations.StableDebtToken}\` |
| VariableDebtToken (unused) | \`${out.implementations.VariableDebtToken}\` |

## Existing mainnet addresses reused

| | Address |
|---|---|
| HOLLAR (GhoToken) | \`${out.existingMainnetAddresses.HOLLAR_GhoToken}\` |
| GhoOracle | \`${out.existingMainnetAddresses.GhoOracle}\` |
| Hydration governance (EVM-mapped) | \`${out.existingMainnetAddresses.AaveManager}\` |
| ZeroDiscountRateStrategy | \`${out.existingMainnetAddresses.ZeroDiscountRateStrategy}\` |
`;

  const mdPath = path.join(deployments, "_addresses.md");
  fs.writeFileSync(mdPath, md);
  console.log(`wrote ${mdPath}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
