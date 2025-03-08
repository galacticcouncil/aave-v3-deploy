"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.HydrationConfig = void 0;
const types_1 = require("./../../helpers/types");
const aave_1 = __importDefault(require("../aave"));
const reservesConfigs_1 = require("./reservesConfigs");
const helpers_1 = require("./helpers");
const helpers_2 = require("../../helpers");
exports.HydrationConfig = {
    ...aave_1.default,
    MarketId: "Hydration Market",
    ATokenNamePrefix: "Hydrated",
    StableDebtTokenNamePrefix: "Hydrated",
    VariableDebtTokenNamePrefix: "Hydrated",
    SymbolPrefix: "Hydrated",
    ProviderId: 222222,
    ReservesConfig: {
        USDC: reservesConfigs_1.strategyUSDC,
        USDT: reservesConfigs_1.strategyUSDT,
        WETH: reservesConfigs_1.strategyWETH,
        WBTC: reservesConfigs_1.strategyWBTC,
        DOT: reservesConfigs_1.strategyDOT,
        VDOT: reservesConfigs_1.strategyVDOT,
    },
    ReserveAssets: {
        [types_1.eHydrationNetwork.hydration]: {
            USDC: (0, helpers_1.tokenAddress)(22),
            USDT: (0, helpers_1.tokenAddress)(10),
            // WETH: tokenAddress(20),
            WBTC: (0, helpers_1.tokenAddress)(19),
            DOT: (0, helpers_1.tokenAddress)(5),
            VDOT: (0, helpers_1.tokenAddress)(15),
        },
        [types_1.eHydrationNetwork.nice]: {
            USDC: (0, helpers_1.tokenAddress)(21),
            USDT: (0, helpers_1.tokenAddress)(10),
            WETH: (0, helpers_1.tokenAddress)(20),
            WBTC: (0, helpers_1.tokenAddress)(3),
            DOT: (0, helpers_1.tokenAddress)(5),
            VDOT: (0, helpers_1.tokenAddress)(15),
        },
        [types_1.eHydrationNetwork.zombie]: {
            USDC: helpers_2.ZERO_ADDRESS,
            USDT: helpers_2.ZERO_ADDRESS,
            // WETH: ZERO_ADDRESS,
            WBTC: helpers_2.ZERO_ADDRESS,
            DOT: helpers_2.ZERO_ADDRESS,
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
        [types_1.eHydrationNetwork.hydration]: {
            USDC: "0x17711BE5D63B2Fe8A2C379725DE720773158b954",
            USDT: "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B",
            WETH: "0x8aEAE0bBf623B0E70732086B8D48A6090C311596",
            WBTC: "0xeDD9A7C47A9F91a0F2db93978A88844167B4a04f",
            DOT: "0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702",
            VDOT: "0xF89728554C61B7AA08bf94823D1017697047c0fE",
        },
        [types_1.eHydrationNetwork.nice]: {
            USDC: "0xEE7aFb45c094DC9fA404D6A86A7d795d4aA33D28",
            USDT: "0xb4aC9f0E6E207D5d81B756F8aF6efe3fe7B0E72c",
            WETH: "0xBd763043861CAF4E7e4E7Ffe951A03dF2Ea7E5AC",
            WBTC: "0xC9cCBe99bdD9538871f9756Ca5Ea64C2267cb0a7",
            DOT: "0x422E745797EC0Ef399c17cE3E2348394F2944727",
            VDOT: "0x1B4A88Ce5A6c6878De2aC19694b2523e14E67eB6",
        },
    },
};
exports.default = exports.HydrationConfig;
