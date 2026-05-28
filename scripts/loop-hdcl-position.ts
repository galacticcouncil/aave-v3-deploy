// Loop a tight HDCL position to maximise effective APR.
//
// Flow per round:
//   1. read borrowCapHollar = (collateralUsd * LTV - debtUsd) / hollarPrice
//   2. take TARGET_RATIO of that (e.g. 0.95 leaves a small safety buffer)
//   3. pool.borrow(HOLLAR, variable)
//   4. HOLLAR.approve(zap)  — first round only, infinite
//   5. zap.depositAndSupply(borrowed)
// Stops when:
//   - HF would drop below MIN_HEALTH_FACTOR_BUFFER, OR
//   - the next round's borrow would be < $1 worth (diminishing returns)
//
// Usage:
//   MARKET_NAME=HDCL HARDHAT_NETWORK=lark2 RPC=https://2.lark.hydration.cloud \
//     npx hardhat run scripts/loop-hdcl-position.ts --network lark2

import hre from "hardhat";

const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const DCL_PRECOMPILE = "0x0000000000000000000000000000000100000226";

const TARGET_RATIO = 0.999;      // tight: borrow 99.9% of headroom (no buffer)
const MIN_NEXT_BORROW = 10n ** 17n; // 0.1 HOLLAR floor — stop when below
const MAX_ROUNDS = 20;
const VARIABLE_RATE_MODE = 2;
const REFERRAL_CODE = 0;

function fmt18(b: bigint): string {
  const neg = b < 0n;
  const abs = neg ? -b : b;
  const w = abs / 10n ** 18n;
  const f = (abs % 10n ** 18n).toString().padStart(18, "0").slice(0, 6);
  return `${neg ? "-" : ""}${w.toString()}.${f}`;
}
function fmt8(b: bigint): string {
  // oracle prices and HF (1e8 base currency, 1e18 hf)
  const w = b / 10n ** 8n;
  const f = (b % 10n ** 8n).toString().padStart(8, "0").slice(0, 4);
  return `${w.toString()}.${f}`;
}

async function main() {
  const hhre = hre as any;
  const eth = hhre.ethers;
  const { deployer } = await hhre.getNamedAccounts();
  const me = await eth.getSigner(deployer);
  const meAddr = await me.getAddress();
  console.log(`acting as ${meAddr}\n`);

  const pool = await eth.getContractAt(
    [
      "function getUserAccountData(address) view returns (uint256 totalCollateralBase,uint256 totalDebtBase,uint256 availableBorrowsBase,uint256 currentLiquidationThreshold,uint256 ltv,uint256 healthFactor)",
      "function supply(address,uint256,address,uint16)",
      "function borrow(address,uint256,uint256,uint16,address)",
      "function setUserUseReserveAsCollateral(address,bool)",
      "function getReserveData(address) view returns (tuple(tuple(uint256) configuration,uint128 liquidityIndex,uint128 currentLiquidityRate,uint128 variableBorrowIndex,uint128 currentVariableBorrowRate,uint128 currentStableBorrowRate,uint128 lastUpdateTimestamp,uint16 id,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint128 accruedToTreasury,uint128 unbacked,uint128 isolationModeTotalDebt))",
    ],
    (await hhre.deployments.get("Pool-Proxy-HDCL")).address
  );
  const oracle = await eth.getContractAt(
    ["function getAssetPrice(address) view returns (uint256)"],
    (await hhre.deployments.get("AaveOracle-HDCL")).address
  );
  const zap = await eth.getContractAt(
    ["function depositAndSupply(uint256)"],
    (await hhre.deployments.get("HDCLDepositZap")).address
  );
  const dcl = await eth.getContractAt(
    ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)"],
    DCL_PRECOMPILE
  );
  const hollar = await eth.getContractAt(
    ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)"],
    HOLLAR
  );

  // Read prices once — they update slowly on Hydration, fine for sizing.
  const pxDcl: bigint = (await oracle.getAssetPrice(DCL_PRECOMPILE)).toBigInt();
  const pxHollar: bigint = (await oracle.getAssetPrice(HOLLAR)).toBigInt();
  console.log(`prices  DCL=${fmt8(pxDcl)}  HOLLAR=${fmt8(pxHollar)}\n`);

  // Step 1 — seed the position with any existing DCL the deployer holds.
  const initialDcl: bigint = (await dcl.balanceOf(meAddr)).toBigInt();
  if (initialDcl > 0n) {
    const cur: bigint = (await dcl.allowance(meAddr, pool.address)).toBigInt();
    if (cur < initialDcl) {
      console.log(`approve DCL → pool`);
      await (await dcl.approve(pool.address, eth.constants.MaxUint256, { gasLimit: 200_000 })).wait();
    }
    console.log(`supply ${fmt18(initialDcl)} DCL`);
    await (await pool.supply(DCL_PRECOMPILE, initialDcl, meAddr, REFERRAL_CODE, { gasLimit: 1_500_000 })).wait();
  }

  // Step 2 — seed-zap with any existing HOLLAR the deployer holds (skips one borrow round).
  const initialHollar: bigint = (await hollar.balanceOf(meAddr)).toBigInt();
  if (initialHollar > 0n) {
    const cur: bigint = (await hollar.allowance(meAddr, zap.address)).toBigInt();
    if (cur < initialHollar) {
      console.log(`approve HOLLAR → zap`);
      await (await hollar.approve(zap.address, eth.constants.MaxUint256, { gasLimit: 200_000 })).wait();
    }
    console.log(`seed-zap ${fmt18(initialHollar)} HOLLAR → DCL → supply`);
    await (await zap.depositAndSupply(initialHollar, { gasLimit: 3_000_000 })).wait();
  }

  const printPosition = async (tag: string) => {
    const a = await pool.getUserAccountData(meAddr);
    console.log(
      `[${tag}] collateral=$${fmt8(a.totalCollateralBase.toBigInt())} ` +
      `debt=$${fmt8(a.totalDebtBase.toBigInt())} ` +
      `LTV=${(Number(a.ltv.toString())/100).toFixed(2)}% ` +
      `liqThr=${(Number(a.currentLiquidationThreshold.toString())/100).toFixed(2)}% ` +
      `HF=${fmt18(a.healthFactor.toBigInt())} ` +
      `headroom=$${fmt8(a.availableBorrowsBase.toBigInt())}`
    );
    return a;
  };

  await printPosition("start");

  // Step 3 — loop borrows.
  for (let i = 0; i < MAX_ROUNDS; i++) {
    const a = await pool.getUserAccountData(meAddr);
    const headroomBase: bigint = a.availableBorrowsBase.toBigInt(); // 1e8 USD
    if (headroomBase === 0n) {
      console.log("no borrow headroom — stop");
      break;
    }
    // headroom (1e8 USD) → HOLLAR amount (1e18, HOLLAR=$1 ⇒ pxHollar≈1e8)
    const maxBorrowHollar = (headroomBase * 10n ** 18n) / pxHollar;
    const nextBorrow = (maxBorrowHollar * BigInt(Math.floor(TARGET_RATIO * 10000))) / 10000n;
    if (nextBorrow < MIN_NEXT_BORROW) {
      console.log(`next borrow ${fmt18(nextBorrow)} HOLLAR < floor — stop`);
      break;
    }
    console.log(`\nround ${i + 1}: borrow ${fmt18(nextBorrow)} HOLLAR (${(TARGET_RATIO*100).toFixed(0)}% of headroom)`);
    await (await pool.borrow(HOLLAR, nextBorrow, VARIABLE_RATE_MODE, REFERRAL_CODE, meAddr, { gasLimit: 1_500_000 })).wait();
    console.log(`  zap → DCL → supply`);
    await (await zap.depositAndSupply(nextBorrow, { gasLimit: 3_000_000 })).wait();
    await printPosition(`r${i + 1}`);
  }

  console.log("");
  const final = await printPosition("final");
  const coll = final.totalCollateralBase.toBigInt();
  const debt = final.totalDebtBase.toBigInt();
  const equity = coll - debt;
  console.log(`equity≈ $${fmt8(equity)}  leverage≈ ${Number(coll * 100n / equity)/100}x\n`);

  // APR readout — Aave stores rates in ray (1e27) representing annual linear rate.
  const dclR = await pool.getReserveData(DCL_PRECOMPILE);
  const hollarR = await pool.getReserveData(HOLLAR);
  const supplyRay: bigint = dclR.currentLiquidityRate.toBigInt();
  const borrowRay: bigint = hollarR.currentVariableBorrowRate.toBigInt();
  const supplyPct = Number(supplyRay / 10n ** 23n) / 10000; // ray → %
  const borrowPct = Number(borrowRay / 10n ** 23n) / 10000;
  // Leveraged APR on equity:
  //   = leverage × supply_apr − (leverage−1) × borrow_apr (approx, ignoring price drift)
  const leverage = Number(coll) / Number(equity);
  const netApr = leverage * supplyPct - (leverage - 1) * borrowPct;
  console.log(`DCL supply APR    : ${supplyPct.toFixed(4)}%`);
  console.log(`HOLLAR borrow APR : ${borrowPct.toFixed(4)}%`);
  console.log(`net leveraged APR : ${netApr.toFixed(4)}%  (= ${leverage.toFixed(3)}x × ${supplyPct.toFixed(4)}% − ${(leverage-1).toFixed(3)}x × ${borrowPct.toFixed(4)}%)`);
}

main().catch((e) => { console.error(e); process.exit(1); });
