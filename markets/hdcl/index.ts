import { eHydrationNetwork, IAaveConfiguration } from "./../../helpers/types";
import AaveMarket from "../aave";
import { strategyDCL } from "./reservesConfigs";
import { rateStrategyStables } from "./rateStrategies";
import { tokenAddress } from "./helpers";

export const HDCLConfig: IAaveConfiguration = {
  ...AaveMarket,
  RateStrategies: {
    ...AaveMarket.RateStrategies,
    rateStrategyStables,
  },
  MarketId: "HDCL",
  ATokenNamePrefix: "HDCL",
  StableDebtTokenNamePrefix: "HDCL",
  VariableDebtTokenNamePrefix: "HDCL",
  SymbolPrefix: "HDCL",
  ProviderId: 22222255,
  // The underlying reserve in this pool is DCL (asset 550, the vault token).
  // The aToken users actually hold is at asset 55 with registry name "HDCL"
  // — see Phase D in tasks/proposals/hdcl.ts for the asset-registry wiring.
  ReservesConfig: {
    DCL: strategyDCL,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      DCL: tokenAddress(550),
    },
    [eHydrationNetwork.nice]: {
      DCL: tokenAddress(550),
    },
    [eHydrationNetwork.zombie]: {
      DCL: tokenAddress(550),
    },
    [eHydrationNetwork.lark]: {
      DCL: tokenAddress(550),
    },
    [eHydrationNetwork.chopsticks]: {
      DCL: tokenAddress(550),
    },
  },
  EModes: {},
  ChainlinkAggregator: {
    // mainnet — populate after HDCLOracleAdapter is deployed on mainnet.
    [eHydrationNetwork.hydration]: {
      DCL: "TODO_DEPLOY_HDCLOracleAdapter",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    // 0.lark — HDCLOracleAdapter deployed 2026-04-23.
    [eHydrationNetwork.lark]: {
      DCL: "0x45edf76c0F2c20fD91639f65444af28440A206ca",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    // chopsticks dry-run — redeploy HDCLOracleAdapter each fresh fork.
    [eHydrationNetwork.chopsticks]: {
      DCL: "TODO_DEPLOY_HDCLOracleAdapter",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    [eHydrationNetwork.zombie]: {
      DCL: "TODO_DEPLOY_HDCLOracleAdapter",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
  },
  IncentivesConfig: {},
  USDOracleAdapter: {},
};

export default HDCLConfig;
