import { eHydrationNetwork, IAaveConfiguration } from "./../../helpers/types";
import AaveMarket from "../aave";
import {
  strategyDOT,
  strategyUSDC,
  strategyUSDT,
  strategyVDOT,
  strategyWBTC,
  strategyWETH,
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
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      USDC: tokenAddress(22),
      USDT: tokenAddress(10),
      // WETH: tokenAddress(20),
      WBTC: tokenAddress(19),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
    },
    [eHydrationNetwork.nice]: {
      USDC: tokenAddress(21),
      USDT: tokenAddress(10),
      WETH: tokenAddress(20),
      WBTC: tokenAddress(3),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
    },
    [eHydrationNetwork.zombie]: {
      USDC: ZERO_ADDRESS,
      USDT: ZERO_ADDRESS,
      // WETH: ZERO_ADDRESS,
      WBTC: ZERO_ADDRESS,
      DOT: ZERO_ADDRESS,
      //VDOT: ZERO_ADDRESS,
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
    },
    [eHydrationNetwork.nice]: {
      USDC: "0xEE7aFb45c094DC9fA404D6A86A7d795d4aA33D28",
      USDT: "0xb4aC9f0E6E207D5d81B756F8aF6efe3fe7B0E72c",
      WETH: "0xBd763043861CAF4E7e4E7Ffe951A03dF2Ea7E5AC",
      WBTC: "0xC9cCBe99bdD9538871f9756Ca5Ea64C2267cb0a7",
      DOT: "0x422E745797EC0Ef399c17cE3E2348394F2944727",
      VDOT: "0x1B4A88Ce5A6c6878De2aC19694b2523e14E67eB6",
    },
  },
};

export default HydrationConfig;
