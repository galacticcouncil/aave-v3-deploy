import { rateStrategyVolatileOne } from "./../aave/rateStrategies";
import { eContractid, IReserveParams } from "../../helpers/types";
import { rateStrategyDOT, rateStrategyStables } from "./rateStrategies";

const supplyCap = "10000000";
const borrowCap = "2000000";
const debtCeiling = "0";
const reserveFactor = "2000";

export const strategyUSDC: IReserveParams = {
  strategy: rateStrategyStables,
  baseLTVAsCollateral: "8000",
  liquidationThreshold: "9000",
  liquidationBonus: "10300",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "6",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
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
  supplyCap: "33",
  borrowCap: "10",
  reserveDecimals: "8",
};

export const strategyDOT: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "7500",
  liquidationThreshold: "8000",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "10",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "22,222,222".replace(/,/g, ""),
  borrowCap: "10,000,000".replace(/,/g, ""),
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
  supplyCap: "1333333",
  borrowCap: "111111",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyTBTC: IReserveParams = {
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
  supplyCap: "33",
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
  supplyCap: "22,222,222".replace(/,/g, ""),
  borrowCap: "0",
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyETH: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "7000",
  liquidationThreshold: "8000",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "2,222".replace(/,/g, ""),
  borrowCap: "1,111".replace(/,/g, ""),
  debtCeiling,
  borrowableIsolation: false,
};

export const strategyGETH: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "6500",
  liquidationThreshold: "7000",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: false,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor,
  supplyCap: "3,333".replace(/,/g, ""),
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
