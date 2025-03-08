"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.strategyVDOT = exports.strategyDOT = exports.strategyWBTC = exports.strategyWETH = exports.strategyUSDT = exports.strategyUSDC = void 0;
const rateStrategies_1 = require("./../aave/rateStrategies");
const types_1 = require("../../helpers/types");
const rateStrategies_2 = require("./rateStrategies");
const supplyCap = "2222222";
const borrowCap = "1111111";
const debtCeiling = "0";
const reserveFactor = "2000";
exports.strategyUSDC = {
    strategy: rateStrategies_2.rateStrategyStables,
    baseLTVAsCollateral: "8000",
    liquidationThreshold: "9000",
    liquidationBonus: "10300",
    liquidationProtocolFee: "1000",
    borrowingEnabled: true,
    stableBorrowRateEnabled: false,
    flashLoanEnabled: false,
    reserveDecimals: "6",
    aTokenImpl: types_1.eContractid.AToken,
    reserveFactor,
    supplyCap,
    borrowCap,
    debtCeiling,
    borrowableIsolation: true,
};
exports.strategyUSDT = exports.strategyUSDC;
exports.strategyWETH = {
    strategy: rateStrategies_1.rateStrategyVolatileOne,
    baseLTVAsCollateral: "7000",
    liquidationThreshold: "8000",
    liquidationBonus: "10500",
    liquidationProtocolFee: "1000",
    borrowingEnabled: true,
    stableBorrowRateEnabled: false,
    flashLoanEnabled: false,
    reserveDecimals: "18",
    aTokenImpl: types_1.eContractid.AToken,
    reserveFactor,
    supplyCap: "850",
    borrowCap: "250",
    debtCeiling,
    borrowableIsolation: false,
};
exports.strategyWBTC = {
    ...exports.strategyWETH,
    baseLTVAsCollateral: "6000",
    liquidationThreshold: "7000",
    supplyCap: "33",
    borrowCap: "10",
    reserveDecimals: "8",
};
exports.strategyDOT = {
    strategy: rateStrategies_2.rateStrategyDOT,
    baseLTVAsCollateral: "7500",
    liquidationThreshold: "8000",
    liquidationBonus: "10700",
    liquidationProtocolFee: "1000",
    borrowingEnabled: true,
    stableBorrowRateEnabled: false,
    flashLoanEnabled: false,
    reserveDecimals: "10",
    aTokenImpl: types_1.eContractid.AToken,
    reserveFactor,
    supplyCap: "9000000",
    borrowCap: "500000",
    debtCeiling,
    borrowableIsolation: false,
};
exports.strategyVDOT = {
    strategy: rateStrategies_2.rateStrategyDOT,
    baseLTVAsCollateral: "6000",
    liquidationThreshold: "7000",
    liquidationBonus: "10800",
    liquidationProtocolFee: "1000",
    borrowingEnabled: true,
    stableBorrowRateEnabled: false,
    flashLoanEnabled: false,
    reserveDecimals: "10",
    aTokenImpl: types_1.eContractid.AToken,
    reserveFactor,
    supplyCap: "633333",
    borrowCap: "111111",
    debtCeiling,
    borrowableIsolation: false,
};
