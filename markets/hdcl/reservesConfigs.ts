import { eContractid, IReserveParams } from "../../helpers/types";
import { rateStrategyStables } from "./rateStrategies";

export const strategyHDCL: IReserveParams = {
  strategy: rateStrategyStables,
  baseLTVAsCollateral: "7000",
  liquidationThreshold: "8000",
  liquidationBonus: "10700",
  liquidationProtocolFee: "1000",
  borrowingEnabled: false,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "18",
  aTokenImpl: eContractid.AToken,
  reserveFactor: "2000",
  supplyCap: "3000000",
  borrowCap: "0",
  debtCeiling: "0",
  borrowableIsolation: false,
};
