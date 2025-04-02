import {
  eHydrationNetwork,
  IAaveConfiguration,
  AssetType,
  TransferStrategy,
} from "./../../helpers/types";
import { POOL_ADMIN } from "./../../helpers/constants";
import { BigNumber } from "ethers";
import AaveMarket from "../aave";
import {
  strategyDOT,
  strategyUSDC,
  strategyUSDT,
  strategyVDOT,
  strategyWBTC,
  strategyWETH,
  strategyTBTC,
  strategyGDOT,
} from "./reservesConfigs";
import { tokenAddress } from "./helpers";
import { ZERO_ADDRESS } from "../../helpers";

export const HydrationConfig: IAaveConfiguration = {
  ...AaveMarket,
  MarketId: "Hydration Market",
  ATokenNamePrefix: "Hydrated",
  StableDebtTokenNamePrefix: "Hydrated",
  VariableDebtTokenNamePrefix: "Hydrated",
  SymbolPrefix: "Hydrated",
  ProviderId: 222222,
  ReservesConfig: {
    USDC: strategyUSDC,
    USDT: strategyUSDT,
    WETH: strategyWETH,
    WBTC: strategyWBTC,
    DOT: strategyDOT,
    VDOT: strategyVDOT,
    TBTC: strategyTBTC,
    GDOT: strategyGDOT,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      USDC: tokenAddress(22),
      USDT: tokenAddress(10),
      // WETH: tokenAddress(20),
      WBTC: tokenAddress(19),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
      TBTC: tokenAddress(1000765),
      GDOT: tokenAddress(690),
    },
    [eHydrationNetwork.nice]: {
      USDC: tokenAddress(21),
      USDT: tokenAddress(10),
      WETH: tokenAddress(20),
      WBTC: tokenAddress(3),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
      GDOT: tokenAddress(69),
      //TBTC: ZERO_ADDRESS
    },
    [eHydrationNetwork.zombie]: {
      USDC: ZERO_ADDRESS,
      USDT: ZERO_ADDRESS,
      // WETH: ZERO_ADDRESS,
      WBTC: ZERO_ADDRESS,
      DOT: ZERO_ADDRESS,
      //VDOT: ZERO_ADDRESS,
      //TBTC: ZERO_ADDRESS,
    },
  },
  EModes: {
    StableEMode: {
      id: "1",
      ltv: "9000",
      liquidationThreshold: "9300",
      liquidationBonus: "10150",
      label: "Stablecoins",
      assets: ["USDC", "USDT"],
    },
    DotEMode: {
      id: "2",
      ltv: "8000",
      liquidationThreshold: "9000",
      liquidationBonus: "10450",
      label: "DOT correlated",
      assets: ["DOT", "VDOT"],
    },
  },
  ChainlinkAggregator: {
    [eHydrationNetwork.hydration]: {
      USDC: "0x17711BE5D63B2Fe8A2C379725DE720773158b954",
      USDT: "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B",
      WETH: "0x8aEAE0bBf623B0E70732086B8D48A6090C311596",
      WBTC: "0xeDD9A7C47A9F91a0F2db93978A88844167B4a04f",
      DOT: "0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702",
      VDOT: "0xF89728554C61B7AA08bf94823D1017697047c0fE",
      TBTC: "0xe5AcDfB0d5EC5cE34F7448B41ef4a97c4e83D9c1",
      GDOT: "0xe5AcDfB0d5EC5cE34F7448B41ef4a97c4e83D9c1", //TODO: this is wrong address
    },
    [eHydrationNetwork.nice]: {
      USDC: "0xEE7aFb45c094DC9fA404D6A86A7d795d4aA33D28",
      USDT: "0xb4aC9f0E6E207D5d81B756F8aF6efe3fe7B0E72c",
      WETH: "0xBd763043861CAF4E7e4E7Ffe951A03dF2Ea7E5AC",
      WBTC: "0xC9cCBe99bdD9538871f9756Ca5Ea64C2267cb0a7",
      DOT: "0x422E745797EC0Ef399c17cE3E2348394F2944727",
      VDOT: "0x234F96059d628Da80B76A40c0E50a9D16a8F3191",
      //TBTC: "0x5d8320f3ced9575d8e25b6f437e610fc6a03bf52",
      GDOT: "0x234F96059d628Da80B76A40c0E50a9D16a8F3191", //TODO: this is vDOT's oracle
    },
  },
  IncentivesConfig: {
    [eHydrationNetwork.hydration]: {
      GDOT: [
        {
          //9k*10^18/(13w*7*86400)
          emissionPerSecond: BigNumber.from("1144688644688644"),
          duration: 7862400,
          reserve: "GDOT",
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(69),
          rewardOracle: "GDOT",
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
        },
      ],
    },
    [eHydrationNetwork.nice]: {
      DOT: [
        {
          emissionPerSecond: BigNumber.from("413359788"),
          duration: 1209600,
          reserve: "DOT",
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(15),
          rewardOracle: "VDOT",
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.nice],
        },
      ],
      GDOT: [
        {
          //9k*10^18/(13w*7*86400)
          emissionPerSecond: BigNumber.from("1144688644688644"),
          duration: 7862400,
          reserve: "GDOT",
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(690),
          rewardOracle: "GDOT",
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.nice],
        },
      ],
    },
  },
};

export default HydrationConfig;
