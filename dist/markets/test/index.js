"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.AaveMarket = void 0;
const helpers_1 = require("../../helpers");
const types_1 = require("../../helpers/types");
const commons_1 = require("./commons");
const reservesConfigs_1 = require("./reservesConfigs");
// ----------------
// POOL--SPECIFIC PARAMS
// ----------------
exports.AaveMarket = {
    ...commons_1.CommonsConfig,
    MarketId: "Testnet Aave Market",
    ProviderId: 8080,
    ReservesConfig: {
        AAVE: reservesConfigs_1.strategyAAVE,
        DAI: reservesConfigs_1.strategyDAI,
        USDC: reservesConfigs_1.strategyUSDC,
        WETH: reservesConfigs_1.strategyWETH,
        LINK: reservesConfigs_1.strategyLINK,
    },
    ReserveAssets: {
        [types_1.eEthereumNetwork.main]: {
            AAVE: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
            DAI: "0x6B175474E89094C44Da98b954EedeAC495271d0F",
            USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
            LINK: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
        },
        [types_1.eEthereumNetwork.kovan]: {
            AAVE: helpers_1.ZERO_ADDRESS,
            DAI: helpers_1.ZERO_ADDRESS,
            USDC: helpers_1.ZERO_ADDRESS,
            WETH: helpers_1.ZERO_ADDRESS,
            LINK: helpers_1.ZERO_ADDRESS,
        },
        [types_1.eArbitrumNetwork.arbitrumTestnet]: {
            AAVE: helpers_1.ZERO_ADDRESS,
            DAI: helpers_1.ZERO_ADDRESS,
            USDC: helpers_1.ZERO_ADDRESS,
            WETH: helpers_1.ZERO_ADDRESS,
            LINK: helpers_1.ZERO_ADDRESS,
        },
        [types_1.eEthereumNetwork.rinkeby]: {
            AAVE: helpers_1.ZERO_ADDRESS,
            DAI: helpers_1.ZERO_ADDRESS,
            USDC: helpers_1.ZERO_ADDRESS,
            WETH: helpers_1.ZERO_ADDRESS,
            LINK: helpers_1.ZERO_ADDRESS,
        },
    },
};
exports.default = exports.AaveMarket;
