import { eContractid, IReserveParams } from "../../helpers/types";
import { rateStrategyDOT } from "./rateStrategies";

export const strategySTHDX: IReserveParams = {
  strategy: rateStrategyDOT,
  baseLTVAsCollateral: "4000",
  liquidationThreshold: "7000",
  liquidationBonus: "10800",
  liquidationProtocolFee: "0",
  borrowingEnabled: false,
  stableBorrowRateEnabled: false,
  flashLoanEnabled: false,
  reserveDecimals: "12",
  aTokenImpl: eContractid.LockableAToken,
  reserveFactor: "2000",
  supplyCap: "0",
  borrowCap: "0",
  debtCeiling: "0",
  borrowableIsolation: false,
};
