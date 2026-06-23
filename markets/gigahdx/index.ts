import { eHydrationNetwork, IAaveConfiguration } from "./../../helpers/types";
import AaveMarket from "../aave";
import { strategySTHDX } from "./reservesConfigs";
import { tokenAddress } from "./helpers";
import { rateStrategyDOT } from "./rateStrategies";

export const GIGAHDXConfig: IAaveConfiguration = {
  ...AaveMarket,
  RateStrategies: {
    ...AaveMarket.RateStrategies,
    rateStrategyDOT,
  },
  MarketId: "GIGAHDX",
  ATokenNamePrefix: "GIGAHDX",
  StableDebtTokenNamePrefix: "GIGAHDX",
  VariableDebtTokenNamePrefix: "GIGAHDX",
  SymbolPrefix: "GIGAHDX",
  ProviderId: 22222269,
  // GIGAHDX is a second market on Hydration mainnet: it shares the existing
  // ecosystem-reserve Treasury proxy rather than deploying its own (the
  // TreasuryProxy artifact name is not market-suffixed). Setting this makes
  // 01_treasury.ts reference the existing proxy instead of re-initializing it.
  ReserveFactorTreasuryAddress: {
    ...AaveMarket.ReserveFactorTreasuryAddress,
    [eHydrationNetwork.hydration]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
    [eHydrationNetwork.gigahdx]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
    [eHydrationNetwork.zombie]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
  },
  ReservesConfig: {
    STHDX: strategySTHDX,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      STHDX: tokenAddress(670),
    },
    [eHydrationNetwork.gigahdx]: {
      STHDX: tokenAddress(670),
    },
    [eHydrationNetwork.nice]: {
      STHDX: tokenAddress(670),
    },
    [eHydrationNetwork.zombie]: {
      STHDX: tokenAddress(670),
    },
  },
  EModes: {},
  // Intentionally empty per network: GIGAHDX's only reserve (STHDX) gets its
  // oracle source from the freshly-deployed `STHDX-USDOracleAdapter` (deploy-all
  // phase 3, built from the gigahdxs + Omnipool-EMA legs in `USDOracleAdapter`
  // below), which `tasks/misc/init-reserve.ts` auto-wires — overriding any address
  // here. If the adapter is somehow not deployed, init-reserve fails loudly
  // ("Missing aggregator for STHDX") instead of wiring a stale hardcoded oracle.
  // The empty object still satisfies the launch task's `if (!chainlinkConf)` check.
  ChainlinkAggregator: {
    [eHydrationNetwork.hydration]: {},
    [eHydrationNetwork.gigahdx]: {},
    [eHydrationNetwork.zombie]: {},
  },
  IncentivesConfig: {},
  USDOracleAdapter: {
    [eHydrationNetwork.hydration]: {
      STHDX: {
        assetToX: "0x0000010267696761686478730000029e00000000", // gigahdxs source: stHDX(670)/HDX(0) TenMinutes
        xToUSD: "0x0000010400000000000000000000000a00000000", // Omnipool EMA HDX/USD, USD(10)/HDX(0) Day (was DIA 0xea63e594…)
      },
    },
    [eHydrationNetwork.gigahdx]: {
      STHDX: {
        assetToX: "0x0000010267696761686478730000029e00000000", // gigahdxs source: stHDX(670)/HDX(0) TenMinutes
        xToUSD: "0x0000010400000000000000000000000a00000000", // Omnipool EMA HDX/USD, USD(10)/HDX(0) Day
      },
    },
    [eHydrationNetwork.zombie]: {
      STHDX: {
        assetToX: "0x0000010267696761686478730000029e00000000", // gigahdxs source: stHDX(670)/HDX(0) TenMinutes
        xToUSD: "0x0000010400000000000000000000000a00000000", // Omnipool EMA HDX/USD, USD(10)/HDX(0) Day (was DIA 0xea63e594…)
      },
    },
  },
};

export default GIGAHDXConfig;
