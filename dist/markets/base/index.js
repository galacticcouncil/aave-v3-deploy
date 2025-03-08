"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.BaseConfig = void 0;
const types_1 = require("./../../helpers/types");
const aave_1 = __importDefault(require("../aave"));
const helpers_1 = require("../../helpers");
const reservesConfigs_1 = require("../aave/reservesConfigs");
exports.BaseConfig = {
    ...aave_1.default,
    MarketId: "Base Aave Market",
    ATokenNamePrefix: "Base",
    StableDebtTokenNamePrefix: "Base",
    VariableDebtTokenNamePrefix: "Base",
    SymbolPrefix: "Base",
    ProviderId: 37,
    ReservesConfig: {
        USDC: reservesConfigs_1.strategyUSDC,
        WETH: reservesConfigs_1.strategyWETH,
        CBETH: reservesConfigs_1.strategyCBETH,
    },
    ReserveAssets: {
        [types_1.eBaseNetwork.base]: {
            USDC: "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca",
            WETH: "0x4200000000000000000000000000000000000006",
            CBETH: "0x2ae3f1ec7f1f5012cfeab0185bfc7aa3cf0dec22",
        },
        [types_1.eBaseNetwork.baseGoerli]: {
            USDC: helpers_1.ZERO_ADDRESS,
            WETH: helpers_1.ZERO_ADDRESS,
            CBETH: helpers_1.ZERO_ADDRESS,
        },
    },
    EModes: {},
    ChainlinkAggregator: {
        [types_1.eBaseNetwork.base]: {
            USDC: "0x7e860098f58bbfc8648a4311b374b1d669a2bc6b",
            WETH: "0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70",
            CBETH: "0xd7818272b9e248357d13057aab0b417af31e817d",
        },
    },
};
exports.default = exports.BaseConfig;
