import { rateStrategyVolatileOne } from "./../aave/rateStrategies";
import { eContractid, IReserveParams } from "../../helpers/types";
import { rateStrategyDOT, rateStrategyStables } from "./rateStrategies";

const supplyCap = "2222222";
const borrowCap = "1111111";
const debtCeiling = "0";

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
  reserveFactor: "1000",
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
  baseLTVAsCollateral: "6500",
  liquidationThreshold: "7500",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: true,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "10",
  aTokenImpl: eContractid.AToken,
  reserveFactor: "1000",
  supplyCap: "500000",
  borrowCap: "150000",
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
  reserveFactor: "1000",
  supplyCap: "333333",
  borrowCap: "111111",
  debtCeiling,
  borrowableIsolation: false,
};
