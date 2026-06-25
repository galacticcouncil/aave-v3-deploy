import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const deployments = path.join(
    __dirname,
    "..",
    "..",
    "deployments",
    hre.network.name
  );
  const artifacts: Record<string, string> = {};

  for (const f of fs.readdirSync(deployments)) {
    if (!f.endsWith(".json")) continue;
    const p = path.join(deployments, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf8"));
      if (j.address) artifacts[f.replace(".json", "")] = j.address;
    } catch {}
  }

  // Known per-market addresses from the BIL config
  const AAVE_MANAGER = "0xaa7e0000000000000000000000000000000aa7e0";
  const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
  const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";
  // BIL underlying (substrate asset 550, the vault token). On the EVM side
  // resolves to the BILVault proxy via the asset precompile.
  const BIL_UNDERLYING = "0x0000000000000000000000000000000100000226";

  // Read live state
  const poolAddr = artifacts["Pool-Proxy-BIL"];
  const pool = await hre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16 id,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint128,uint128,uint128))"
    ],
    poolAddr
  );

  const bilData = await pool.getReserveData(BIL_UNDERLYING);
  const hollarData = await pool.getReserveData(HOLLAR);

  const out = {
    name: "BIL on Hydration",
    description:
      "Second Aave V3 money market instance on Hydration. BIL collateral-only (yield-bearing vault share over Decentral Protocol positions), HOLLAR borrow-only via GhoAToken facilitator.",
    network: {
      chainId: 222222,
      rpcUrl: process.env.RPC || process.env.RPC_URL || "https://rpc.hydradx.cloud",
      wsUrl: process.env.WS_URL || "wss://rpc.hydradx.cloud",
      marketId: "BIL",
      providerId: 22222255,
    },
    core: {
      Pool: artifacts["Pool-Proxy-BIL"],
      PoolAddressesProvider: artifacts["PoolAddressesProvider-BIL"],
      PoolConfigurator: artifacts["PoolConfigurator-Proxy-BIL"],
      ACLManager: artifacts["ACLManager-BIL"],
      AaveOracle: artifacts["AaveOracle-BIL"],
      PoolDataProvider: artifacts["PoolDataProvider-BIL"],
      PoolAddressesProviderRegistry: artifacts["PoolAddressesProviderRegistry"],
      Treasury: artifacts["TreasuryProxy"],
      IncentivesProxy: artifacts["IncentivesProxy"],
      EmissionManager: artifacts["EmissionManager"],
    },
    vault: {
      // BILVault stack — deployed via scripts/deploy-bil-vault.mjs (Phase 0a).
      // These point at the proxy + impl + library + oracle adapter.
      VaultProxy: artifacts["BILVault"],
      VaultImpl: artifacts["BILVault-Implementation"],
      QueueLib: artifacts["QueueLib"],
      BILOracle: artifacts["BILOracle"],
      BILOracleAdapter: artifacts["BILOracleAdapter"],
      DepositZap: artifacts["BILDepositZap"],
    },
    admin: AAVE_MANAGER,
    reserves: {
      BIL: {
        underlying: BIL_UNDERLYING,
        substrateAssetId: 550,
        aToken: bilData.aTokenAddress,
        substrateATokenAssetId: 55,
        variableDebtToken: bilData.variableDebtTokenAddress,
        stableDebtToken: bilData.stableDebtTokenAddress,
        interestRateStrategy: bilData.interestRateStrategyAddress,
        oracleSource: artifacts["BILOracleAdapter"],
        risk: "LTV 80%, LT 85%, LB 7%, RF 20%, supply-only, 3M supply cap",
      },
      HOLLAR: {
        underlying: HOLLAR,
        aToken_GhoAToken: hollarData.aTokenAddress,
        variableDebtToken: hollarData.variableDebtTokenAddress,
        stableDebtToken: hollarData.stableDebtTokenAddress,
        interestRateStrategy: hollarData.interestRateStrategyAddress,
        oracleSource_GhoOracle: GHO_ORACLE,
        risk: "no collateral value, borrow-only. 1M HOLLAR facilitator bucket on HOLLAR token.",
      },
    },
    implementations: {
      AToken: artifacts["AToken-BIL"],
      DelegationAwareAToken: artifacts["DelegationAwareAToken-BIL"],
      StableDebtToken: artifacts["StableDebtToken-BIL"],
      VariableDebtToken: artifacts["VariableDebtToken-BIL"],
      GhoAToken: artifacts["GhoAToken-BIL"],
      GhoVariableDebtToken: artifacts["GhoVariableDebtToken-BIL"],
      GhoStableDebtToken: artifacts["GhoStableDebtToken-BIL"],
      GhoInterestRateStrategy: artifacts["GhoInterestRateStrategy-BIL"],
      Pool_Implementation: artifacts["Pool-Implementation"],
      PoolConfigurator_Implementation: artifacts["PoolConfigurator-Implementation"],
    },
    rateStrategies: {
      Stables: artifacts["ReserveStrategy-rateStrategyStables"],
      StableOne: artifacts["ReserveStrategy-rateStrategyStableOne"],
      StableTwo: artifacts["ReserveStrategy-rateStrategyStableTwo"],
      VolatileOne: artifacts["ReserveStrategy-rateStrategyVolatileOne"],
    },
    existingMainnetAddresses: {
      HOLLAR_GhoToken: HOLLAR,
      GhoOracle: GHO_ORACLE,
      AaveManager: AAVE_MANAGER,
      ZeroDiscountRateStrategy:
        artifacts["ZeroDiscountRateStrategy"] ??
        "0x33A7C640140FEBafEcC9801AF723A0C14420eEd7",
    },
  };

  const jsonPath = path.join(deployments, "_addresses.json");
  fs.writeFileSync(jsonPath, JSON.stringify(out, null, 2));
  console.log(`wrote ${jsonPath}`);

  // Markdown version
  const md = `# BIL on Hydration — Addresses for Frontend Integration

Second Aave V3 money market instance on Hydration. BIL (Brazilian Invoice Loans, the
yield-bearing vault share over Decentral Protocol positions) is the collateral
asset; HOLLAR is borrow-only via the GhoAToken facilitator.

- **RPC:** ${out.network.rpcUrl}
- **WS:** ${out.network.wsUrl}
- **chainId:** \`${out.network.chainId}\`
- **Market ID:** \`${out.network.marketId}\`
- **ProviderId:** \`${out.network.providerId}\`

Machine-readable version: \`deployments/${hre.network.name}/_addresses.json\`.

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

All admin roles on BIL are held by Hydration governance: \`${out.admin}\`.

## BIL Vault stack

The vault is what gives BIL its yield — it wraps Decentral Protocol NFT lending
positions and exposes ERC-4626 (deposit) + ERC-7540 (async redeem) on top.

| Contract | Address |
|---|---|
| BILVault (proxy) | \`${out.vault.VaultProxy}\` |
| BILVault impl | \`${out.vault.VaultImpl}\` |
| QueueLib (delegate-called library) | \`${out.vault.QueueLib}\` |
| BILOracle (Chainlink-V3 reader of \`vault.exchangeRate()\`) | \`${out.vault.BILOracle}\` |
| BILOracleAdapter (IEACAggregatorProxy on top of BILOracle, used by Aave) | \`${out.vault.BILOracleAdapter}\` |
| BILDepositZap (atomic HOLLAR→BIL→aBIL helper) | \`${out.vault.DepositZap}\` |

## Reserves

### BIL (collateral-only)

| | Address |
|---|---|
| Underlying | \`${out.reserves.BIL.underlying}\` (substrate asset **550**, 18 decimals, vault token) |
| **aToken (aBIL)** | **\`${out.reserves.BIL.aToken}\`** (standard AToken, substrate asset **55**) |
| variableDebtToken | \`${out.reserves.BIL.variableDebtToken}\` |
| stableDebtToken | \`${out.reserves.BIL.stableDebtToken}\` (unused) |
| rateStrategy | \`${out.reserves.BIL.interestRateStrategy}\` (Stables curve) |
| oracle source | \`${out.reserves.BIL.oracleSource}\` (BILOracleAdapter — reads vault.exchangeRate()) |

**Risk:** ${out.reserves.BIL.risk}. Borrow disabled.

### HOLLAR (borrow-only)

| | Address |
|---|---|
| Underlying | \`${out.reserves.HOLLAR.underlying}\` (18 decimals, existing mainnet token) |
| **aToken (GhoAToken)** | **\`${out.reserves.HOLLAR.aToken_GhoAToken}\`** — also the **HOLLAR facilitator** (1M bucket capacity) |
| variableDebtToken | \`${out.reserves.HOLLAR.variableDebtToken}\` |
| stableDebtToken | \`${out.reserves.HOLLAR.stableDebtToken}\` (unused) |
| rateStrategy | \`${out.reserves.HOLLAR.interestRateStrategy}\` (10% fixed APY) |
| oracle source | \`${out.reserves.HOLLAR.oracleSource_GhoOracle}\` (GhoOracle, $1 fixed) |

**Risk:** ${out.reserves.HOLLAR.risk}

## Implementation contracts

| | Address |
|---|---|
| AToken impl | \`${out.implementations.AToken}\` |
| DelegationAwareAToken impl | \`${out.implementations.DelegationAwareAToken}\` |
| StableDebtToken impl | \`${out.implementations.StableDebtToken}\` |
| VariableDebtToken impl | \`${out.implementations.VariableDebtToken}\` |
| GhoAToken impl | \`${out.implementations.GhoAToken}\` |
| GhoVariableDebtToken impl | \`${out.implementations.GhoVariableDebtToken}\` |
| GhoStableDebtToken impl | \`${out.implementations.GhoStableDebtToken}\` |
| GhoInterestRateStrategy | \`${out.implementations.GhoInterestRateStrategy}\` |
| Pool Implementation | \`${out.implementations.Pool_Implementation}\` |
| PoolConfigurator Implementation | \`${out.implementations.PoolConfigurator_Implementation}\` |

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

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
