import { eHydrationNetwork, IAaveConfiguration } from "./../../helpers/types";
import AaveMarket from "../aave";
import { strategySTHDX } from "./reservesConfigs";
import { tokenAddress } from "./helpers";

export const GIGAHDXConfig: IAaveConfiguration = {
  ...AaveMarket,
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
      STHDX: "0x202df3eDac2775b857ee2f61A3569731E53eC713", // USDOracleAdapter: stHDX(670)/HDX(0) -> HDX/USD
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    [eHydrationNetwork.zombie]: {
      STHDX: "0x202df3eDac2775b857ee2f61A3569731E53eC713",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
  },
  IncentivesConfig: {},
  USDOracleAdapter: {
    [eHydrationNetwork.hydration]: {
      STHDX: {
        assetToX: "0x0000010267696761686478730000029e00000000", // gigahdxs source: stHDX(670)/HDX(0) TenMinutes
        xToUSD: "0xea63e594ee00590938E856F2134E6C792bA92d13", // HDX/USD oracle
      },
    },
    [eHydrationNetwork.zombie]: {
      STHDX: {
        assetToX: "0x0000010267696761686478730000029e00000000", // gigahdxs source: stHDX(670)/HDX(0) TenMinutes
        xToUSD: "0xea63e594ee00590938E856F2134E6C792bA92d13", // HDX/USD oracle
      },
    },
  },
};

export default GIGAHDXConfig;
