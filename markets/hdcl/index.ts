import { eHydrationNetwork, IAaveConfiguration } from "./../../helpers/types";
import AaveMarket from "../aave";
import { strategyHDCL } from "./reservesConfigs";
import { tokenAddress } from "./helpers";

export const HDCLConfig: IAaveConfiguration = {
  ...AaveMarket,
  MarketId: "HDCL",
  ATokenNamePrefix: "HDCL",
  StableDebtTokenNamePrefix: "HDCL",
  VariableDebtTokenNamePrefix: "HDCL",
  SymbolPrefix: "HDCL",
  ProviderId: 22222255,
  ReservesConfig: {
    HDCL: strategyHDCL,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      HDCL: tokenAddress(55),
    },
    [eHydrationNetwork.nice]: {
      HDCL: tokenAddress(55),
    },
    [eHydrationNetwork.zombie]: {
      HDCL: tokenAddress(55),
    },
  },
  EModes: {},
  ChainlinkAggregator: {
    [eHydrationNetwork.hydration]: {
      HDCL: "0x45edf76c0F2c20fD91639f65444af28440A206ca", // HDCLOracleAdapter reading vault.exchangeRate()
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    [eHydrationNetwork.zombie]: {
      HDCL: "0x45edf76c0F2c20fD91639f65444af28440A206ca",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
  },
  IncentivesConfig: {},
  USDOracleAdapter: {},
};

export default HDCLConfig;
