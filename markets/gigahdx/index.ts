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
  ReservesConfig: {
    STHDX: strategySTHDX,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
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
  ChainlinkAggregator: {
    [eHydrationNetwork.hydration]: {
      // ⚠️ DIA-era USDOracleAdapter. The xToUSD leg changed to the Omnipool EMA
      // below — redeploy with `deploy-USDOracleAdapter --oracle STHDX` and
      // replace this address with the new adapter before submitting the proposal.
      STHDX: "0x202df3eDac2775b857ee2f61A3569731E53eC713", // USDOracleAdapter: stHDX(670)/HDX(0) -> HDX/USD
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    [eHydrationNetwork.zombie]: {
      // ⚠️ same as above — replace after redeploying the Omnipool-EMA adapter.
      STHDX: "0x202df3eDac2775b857ee2f61A3569731E53eC713",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
  },
  IncentivesConfig: {},
  USDOracleAdapter: {
    [eHydrationNetwork.hydration]: {
      STHDX: {
        assetToX: "0x0000010267696761686478730000029e00000000", // gigahdxs source: stHDX(670)/HDX(0) TenMinutes
        xToUSD: "0x0000010400000000000000000000000a00000000", // Omnipool EMA HDX/USD, USD(10)/HDX(0) Day (was DIA 0xea63e594…)
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
