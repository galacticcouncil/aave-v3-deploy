const { ethers } = require("ethers");
const POOL = "0xb952AE92cC4D8D703d2d71Ab541baB34c94b944A";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const STHDX_PRECOMPILE = "0x000000000000000000000000000000010000029e";
const RPC = "https://2.lark.hydration.cloud";
(async () => {
  const p = new ethers.providers.JsonRpcProvider(RPC);
  const pool = new ethers.Contract(POOL, [
    "function getReservesList() view returns (address[])",
    "function getReserveData(address) view returns (tuple(uint256 configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
  ], p);
  const reserves = await pool.getReservesList();
  console.log("getReservesList():", reserves);

  for (const r of reserves) {
    const d = await pool.getReserveData(r);
    console.log(`\nReserve ${r}:`);
    console.log("  aToken:           ", d.aTokenAddress);
    console.log("  stableDebt:       ", d.stableDebtTokenAddress);
    console.log("  variableDebt:     ", d.variableDebtTokenAddress);
    console.log("  interestRate:     ", d.interestRateStrategyAddress);
  }

  // HOLLAR facilitator
  const hollar = new ethers.Contract(HOLLAR, [
    "function getFacilitator(address) view returns (tuple(string label, uint128 bucketCapacity, uint128 bucketLevel))",
  ], p);
  const hollarReserve = reserves.find(r => r.toLowerCase() === HOLLAR.toLowerCase());
  if (hollarReserve) {
    const d = await pool.getReserveData(HOLLAR);
    const realGhoAToken = d.aTokenAddress;
    const fac = await hollar.getFacilitator(realGhoAToken);
    console.log(`\nFacilitator on ${realGhoAToken}:`);
    console.log("  label:        ", fac.label);
    console.log("  bucketCap:    ", fac.bucketCapacity.toString());
    console.log("  bucketLevel:  ", fac.bucketLevel.toString());

    // GhoAToken cross-refs
    const ghoAToken = new ethers.Contract(realGhoAToken, [
      "function getVariableDebtToken() view returns (address)",
      "function getGhoTreasury() view returns (address)",
    ], p);
    console.log(`\nGhoAToken (${realGhoAToken}) cross-refs:`);
    console.log("  variableDebt: ", await ghoAToken.getVariableDebtToken());
    console.log("  ghoTreasury:  ", await ghoAToken.getGhoTreasury());

    // varDebt cross-refs
    const varDebt = new ethers.Contract(d.variableDebtTokenAddress, [
      "function getAToken() view returns (address)",
      "function getDiscountToken() view returns (address)",
      "function getDiscountRateStrategy() view returns (address)",
    ], p);
    console.log(`\nvarDebt (${d.variableDebtTokenAddress}) cross-refs:`);
    console.log("  aToken:           ", await varDebt.getAToken());
    console.log("  discountToken:    ", await varDebt.getDiscountToken());
    console.log("  discountStrategy: ", await varDebt.getDiscountRateStrategy());
  }
})().catch(e => { console.error("FAILED:", e.message); process.exit(1); });
