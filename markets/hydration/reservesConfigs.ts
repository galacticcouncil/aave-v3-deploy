import { rateStrategyVolatileOne } from "./../aave/rateStrategies";
import { eContractid, IReserveParams } from "../../helpers/types";
import {
  rateStrategyDOT,
  rateStrategyDOT5,
  rateStrategyStables,
  rateStrategyStables80,
} from "./rateStrategies";

const supplyCap = "12000000";
const borrowCap = "6000000";
const debtCeiling = "0";
const reserveFactor = "2000";

export const strategyUSDC: IReserveParams = {
  strategy: rateStrategyStables80,
  baseLTVAsCollateral: "8000",
  liquidationThreshold: "9000",
  liquidationBonus: "10300",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "6",
  aTokenImpl: eContractid.AToken,
  reserveFactor: "1000",
  supplyCap,
  borrowCap,
  debtCeiling,
  borrowableIsolation: true,
};

export const strategyUSDT = strategyUSDC;

export const strategyWETH: IReserveParams = {
  strategy: rateStrategyVolatileOne,
  baseLTVAsCollateral: "7000",
  liquidationThreshold: "8000",
  liquidationBonus: "10500",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "850",
  borrowCap: "250",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyWBTC = {
  ...strategyWETH,
  baseLTVAsCollateral: "6000",
  liquidationThreshold: "7000",
  supplyCap: "1",
  borrowCap: "10",
  reserveDecimals: "8",
};

export const strategyDOT: IReserveParams = {
  strategy: rateStrategyDOT5,
  baseLTVAsCollateral: "8000",
  liquidationThreshold: "8500",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "10",
  aTokenImpl: eContractid.AToken,
  reserveFactor: "1000",
  supplyCap: "25,000,000".replace(/,/g, ""),
  borrowCap: "17,000,000".replace(/,/g, ""),
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyVDOT: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "6000",
  liquidationThreshold: "7000",
  liquidationBonus: "10800",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "10",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "2,222,222".replace(/,/g, ""),
  borrowCap: "111111",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyTBTC: IReserveParams = {
  strategy: rateStrategyVolatileOne,
  baseLTVAsCollateral: "8000",
  liquidationThreshold: "8500",
  liquidationBonus: "10500",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "50",
  borrowCap: "20",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyGDOT: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "6900",
  liquidationThreshold: "7500",
  liquidationBonus: "10750",
  liquidationProtocolFee: "1000",
  borrowingEnabled: false,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "30,000,000".replace(/,/g, ""),
  borrowCap: "0",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyETH: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "7500",
  liquidationThreshold: "8500",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "4,444".replace(/,/g, ""),
  borrowCap: "2,222".replace(/,/g, ""),
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyGETH: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "8000",
  liquidationThreshold: "8500",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: false,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "8,000".replace(/,/g, ""),
  borrowCap: "0",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategy3POOL: IReserveParams = {
  strategy: rateStrategyStables,
  baseLTVAsCollateral: "7500",
  liquidationThreshold: "8500",
  liquidationBonus: "10350",
  liquidationProtocolFee: "1000",
  borrowingEnabled: false,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "5,000,000".replace(/,/g, ""),
  borrowCap: "0",
  debtCeiling,
  borrowableIsolation: false,
};

const strategyHtoken: IReserveParams = {
  ...strategy3POOL,
  baseLTVAsCollateral: "7000",
  liquidationThreshold: "8000",
};

export const strategyHUSDT: IReserveParams = {
  ...strategyHtoken,
  supplyCap: "8,000,000".replace(/,/g, ""),
};

export const strategyHUSDC: IReserveParams = {
  ...strategyHtoken,
  supplyCap: "8,000,000".replace(/,/g, ""),
};

export const strategyHUSDS: IReserveParams = {
  ...strategyHtoken,
  supplyCap: "4,000,000".replace(/,/g, ""),
};

export const strategyHUSDe: IReserveParams = {
  ...strategyHtoken,
  supplyCap: "4,000,000".replace(/,/g, ""),
};

export const strategyPAXG: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "7000",
  liquidationThreshold: "7500",
  liquidationBonus: "10500",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "250",
  borrowCap: "175",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyPRIME: IReserveParams = {
  strategy: rateStrategyVolatileOne,
  baseLTVAsCollateral: "8500",
  liquidationThreshold: "8800",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "6",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "5000000",
  borrowCap: "3000000",
  debtCeiling: "400000000",
  borrowableIsolation: false,
};

// GIGASOL reserve configurations
export const strategySOL: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "7000",
  liquidationThreshold: "7500",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "9", // SOL has 9 decimals
  aTokenImpl: eContractid.AToken,
  reserveFactor, // 20%
  supplyCap: "50,000".replace(/,/g, ""),
  borrowCap: "25,000".replace(/,/g, ""),
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyGSOL: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "6000",
  liquidationThreshold: "7000",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: false, // Stablepool LP tokens cannot be borrowed
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18", // LP tokens use 18 decimals
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "100,000".replace(/,/g, ""),
  borrowCap: "0",
  debtCeiling,
  borrowableIsolation: false,
};

// HEURC reserve configurations
export const strategyEURC: IReserveParams = {
  strategy: rateStrategyStables80,
  baseLTVAsCollateral: "7500",
  liquidationThreshold: "8000",
  liquidationBonus: "10300",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "6", // EURC has 6 decimals
  aTokenImpl: eContractid.AToken,
  reserveFactor: "1000",
  supplyCap: "4,000,000".replace(/,/g, ""),
  borrowCap: "3,500,000".replace(/,/g, ""),
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyHEURC: IReserveParams = {
  ...strategyHtoken,
  supplyCap: "8,000,000".replace(/,/g, ""),
};
