"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.rateStrategyStables = exports.rateStrategyDOT = void 0;
const utils_1 = require("ethers/lib/utils");
exports.rateStrategyDOT = {
    name: "rateStrategyDOT",
    optimalUsageRatio: (0, utils_1.parseUnits)("0.75", 27).toString(),
    baseVariableBorrowRate: "0",
    variableRateSlope1: (0, utils_1.parseUnits)("0.07", 27).toString(),
    variableRateSlope2: (0, utils_1.parseUnits)("3", 27).toString(),
    stableRateSlope1: (0, utils_1.parseUnits)("0.07", 27).toString(),
    stableRateSlope2: (0, utils_1.parseUnits)("3", 27).toString(),
    baseStableRateOffset: (0, utils_1.parseUnits)("0.02", 27).toString(),
    stableRateExcessOffset: (0, utils_1.parseUnits)("0.05", 27).toString(),
    optimalStableToTotalDebtRatio: (0, utils_1.parseUnits)("0.2", 27).toString(),
};
exports.rateStrategyStables = {
    name: "rateStrategyStables",
    optimalUsageRatio: (0, utils_1.parseUnits)("0.85", 27).toString(),
    baseVariableBorrowRate: (0, utils_1.parseUnits)("0", 27).toString(),
    variableRateSlope1: (0, utils_1.parseUnits)("0.04", 27).toString(),
    variableRateSlope2: (0, utils_1.parseUnits)("0.6", 27).toString(),
    stableRateSlope1: (0, utils_1.parseUnits)("0.005", 27).toString(),
    stableRateSlope2: (0, utils_1.parseUnits)("0.6", 27).toString(),
    baseStableRateOffset: (0, utils_1.parseUnits)("0.01", 27).toString(),
    stableRateExcessOffset: (0, utils_1.parseUnits)("0.08", 27).toString(),
    optimalStableToTotalDebtRatio: (0, utils_1.parseUnits)("0.2", 27).toString(),
};
