import { eHydrationNetwork, IAaveConfiguration } from "./../../helpers/types";
import AaveMarket from "../aave";
import { strategyDCL } from "./reservesConfigs";
import { rateStrategyStables } from "./rateStrategies";
import { tokenAddress } from "./helpers";

export const BILConfig: IAaveConfiguration = {
  ...AaveMarket,
  RateStrategies: {
    ...AaveMarket.RateStrategies,
    rateStrategyStables,
  },
  MarketId: "BIL",
  ATokenNamePrefix: "BIL",
  StableDebtTokenNamePrefix: "BIL",
  VariableDebtTokenNamePrefix: "BIL",
  SymbolPrefix: "BIL",
  ProviderId: 22222255,
  // The underlying reserve in this pool is BIL (asset 550, the vault token).
  // The aToken users actually hold is at asset 55 with registry name "BIL"
  // — see Phase D in tasks/proposals/bil.ts for the asset-registry wiring.
  ReservesConfig: {
    BIL: strategyDCL,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      BIL: tokenAddress(550),
    },
    [eHydrationNetwork.nice]: {
      BIL: tokenAddress(550),
    },
    [eHydrationNetwork.zombie]: {
      BIL: tokenAddress(550),
    },
    [eHydrationNetwork.lark]: {
      BIL: tokenAddress(550),
    },
    // 2.lark — BIL must be registered as a substrate Erc20 asset pointing at
    // the lark-2 vault (0xbDAFEB92440d8696d6C143bc7e6B086d461e3502) during the
    // governance proposal (Phase D in tasks/proposals/bil.ts). Asset id 550
    // mirrors the established scheme; confirm/assign during that step.
    [eHydrationNetwork.lark2]: {
      BIL: tokenAddress(550),
    },
    [eHydrationNetwork.chopsticks]: {
      BIL: tokenAddress(550),
    },
  },
  // Reuse the main Hydration money-market treasury as the reserve-factor
  // recipient instead of standing up a fresh one. lark-2 is a mainnet-state
  // fork, so this address exists there too — and using the same value for
  // `hydration` keeps the eventual mainnet run identical to the lark-2
  // rehearsal. The treasury deploy step (deploy/01_periphery_pre/01_treasury.ts)
  // sees a non-zero address here and adopts it (no new treasury deployed).
  ReserveFactorTreasuryAddress: {
    [eHydrationNetwork.hydration]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
    [eHydrationNetwork.lark]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
    [eHydrationNetwork.lark2]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
    [eHydrationNetwork.chopsticks]: "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9",
  },
  EModes: {},
  ChainlinkAggregator: {
    // mainnet — BIL aggregator is auto-wired by init-reserve from the freshly
    // deployed BILOracleAdapter artifact (see scripts/bil/deploy-all.sh phase 2).
    // No hardcoded address: getPairsTokenAggregator skips the BIL entry during
    // AaveOracle deploy, and init-reserve fills it via setAssetSources later.
    [eHydrationNetwork.hydration]: {
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    // 0.lark — BILOracleAdapter deployed 2026-04-23.
    [eHydrationNetwork.lark]: {
      BIL: "0x45edf76c0F2c20fD91639f65444af28440A206ca",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    // 2.lark — deploy a fresh BILOracleAdapter against the lark-2 vault and
    // paste its address here:
    //   HARDHAT_NETWORK=lark2 npx hardhat deploy-BILOracleAdapter \
    //     --vault 0xbDAFEB92440d8696d6C143bc7e6B086d461e3502
    // (The raw BILOracle at 0x8DFD81…93Fa reads the same exchangeRate but only
    // implements the slim AggregatorV3 interface; the adapter adds the
    // IEACAggregatorProxy surface Aave's oracle infra + MMOracle peg resolver
    // expect, so deploy the adapter rather than pointing at BILOracle.)
    // 2.lark — BILOracleAdapter deployed 2026-05-27 against vault 0xbDAFEB….
    [eHydrationNetwork.lark2]: {
      BIL: "0xAc4C01AbA189d90eCD707938D545f47535843642",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    // chopsticks dry-run — adapter is auto-wired by init-reserve from the
    // freshly deployed BILOracleAdapter artifact.
    [eHydrationNetwork.chopsticks]: {
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
    [eHydrationNetwork.zombie]: {
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
    },
  },
  IncentivesConfig: {},
  USDOracleAdapter: {},
};

export default BILConfig;
