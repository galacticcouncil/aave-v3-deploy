import { eContractid, IReserveParams } from "../../helpers/types";
import { rateStrategyStables } from "./rateStrategies";

// Reserve config for DCL — the underlying vault token in the HDCL Aave pool.
// Asset id 550 in the substrate registry. The aToken receipt for this reserve
// is what users hold (asset id 55, registry name "HDCL"), since user
// positions are auto-deposited into the pool.
export const strategyDCL: IReserveParams = {
  strategy: rateStrategyStables,
  baseLTVAsCollateral: "8000",
  liquidationThreshold: "8500",
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
