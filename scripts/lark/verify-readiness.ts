// Read-only verification of the GIGAHDX lark2 deployment. Mirrors exactly the
// queries Max and Juraj would make from their tooling.
//
// Usage:
//   WS_URL=wss://2.lark.hydration.cloud RPC_URL=https://2.lark.hydration.cloud \
//     npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
//     scripts/lark/verify-readiness.ts
//
// Requires deployments/lark2/_addresses.json (run scripts/lark/generate-addresses.ts first).
//
// No transactions are sent; this script only reads on-chain state. Output is a
// PASS/FAIL table grouped by concern.

import { ApiPromise, WsProvider } from "@polkadot/api";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const RPC = process.env.RPC_URL || "https://2.lark.hydration.cloud";
const SHEET = path.join(__dirname, "..", "..", "deployments", "lark2", "_addresses.json");

type Result = { group: string; name: string; ok: boolean; detail: string };
const results: Result[] = [];
function add(group: string, name: string, ok: boolean, detail = "") {
  results.push({ group, name, ok, detail });
}

async function main() {
  if (!fs.existsSync(SHEET)) throw new Error(`address sheet not found: ${SHEET}`);
  const sheet = JSON.parse(fs.readFileSync(SHEET, "utf8"));
  const provider = new ethers.providers.JsonRpcProvider(RPC);

  console.log(`Verifying GIGAHDX on lark 2`);
  console.log(`  WS:  ${WS}`);
  console.log(`  RPC: ${RPC}`);
  console.log(`  Address sheet: ${path.basename(SHEET)}\n`);

  // ===================================================================
  // A. Substrate runtime + pallets
  // ===================================================================
  const api = await ApiPromise.create({ provider: new WsProvider(WS) });
  const ver = await api.rpc.state.getRuntimeVersion();
  add("A. Runtime", `specVersion ≥ 406`, ver.specVersion.toNumber() >= 406, `got ${ver.specVersion.toNumber()}`);

  const pallets = Object.keys(api.tx);
  for (const need of ["gigaHdx", "gigaHdxVoting", "feeProcessor"]) {
    add("A. Runtime", `pallet ${need} present`, pallets.includes(need));
  }

  // ===================================================================
  // B. Substrate state — assetRegistry, gigaHdxPoolContract (the wiring fix)
  // ===================================================================
  const sthdxAsset: any = await api.query.assetRegistry.assets(670);
  add(
    "B. Substrate state",
    "assetRegistry.assets(670) stHDX registered",
    sthdxAsset.isSome,
    sthdxAsset.isSome ? JSON.stringify(sthdxAsset.toHuman()) : ""
  );

  const gigaAsset: any = await api.query.assetRegistry.assets(67);
  add(
    "B. Substrate state",
    "assetRegistry.assets(67) GIGAHDX registered as Erc20",
    gigaAsset.isSome && (gigaAsset.toHuman() as any)?.assetType === "Erc20",
    gigaAsset.isSome ? `assetType=${(gigaAsset.toHuman() as any)?.assetType}` : ""
  );

  // The "fixed by a call" thing for gigaStake routing — ref 321 set this.
  const poolPtr: any = await api.query.liquidation.gigaHdxPoolContract();
  const expectedPool = (sheet.core.Pool as string).toLowerCase();
  add(
    "B. Substrate state",
    "pallet_liquidation::gigaHdxPoolContract → sheet.Pool",
    poolPtr.toString().toLowerCase() === expectedPool,
    `runtime=${poolPtr.toString()} sheet=${sheet.core.Pool}`
  );

  // ===================================================================
  // C. EVM core contracts have code at the addresses the sheet claims
  // ===================================================================
  const coreContracts: Record<string, string> = {
    Pool: sheet.core.Pool,
    PoolAddressesProvider: sheet.core.PoolAddressesProvider,
    PoolConfigurator: sheet.core.PoolConfigurator,
    ACLManager: sheet.core.ACLManager,
    AaveOracle: sheet.core.AaveOracle,
    PoolDataProvider: sheet.core.PoolDataProvider,
    Treasury: sheet.core.Treasury,
  };
  for (const [name, addr] of Object.entries(coreContracts)) {
    const code = await provider.getCode(addr);
    add("C. EVM core", `${name} code at ${addr}`, code !== "0x" && code.length > 2, `${code.length} bytes`);
  }

  // PoolAddressesProvider should agree with the sheet's Pool/AaveOracle/etc.
  const pap = new ethers.Contract(sheet.core.PoolAddressesProvider, [
    "function getPool() view returns (address)",
    "function getPoolDataProvider() view returns (address)",
    "function getPriceOracle() view returns (address)",
    "function getACLManager() view returns (address)",
    "function getACLAdmin() view returns (address)",
    "function owner() view returns (address)",
  ], provider);
  add("C. EVM core", "PAP.getPool == sheet.Pool", (await pap.getPool()).toLowerCase() === expectedPool);
  add("C. EVM core", "PAP.getPoolDataProvider == sheet.PoolDataProvider",
    (await pap.getPoolDataProvider()).toLowerCase() === sheet.core.PoolDataProvider.toLowerCase());
  add("C. EVM core", "PAP.getPriceOracle == sheet.AaveOracle",
    (await pap.getPriceOracle()).toLowerCase() === sheet.core.AaveOracle.toLowerCase());
  add("C. EVM core", "PAP.getACLManager == sheet.ACLManager",
    (await pap.getACLManager()).toLowerCase() === sheet.core.ACLManager.toLowerCase());

  // Admin = governance precompile (the transfer-admin-to-governance step)
  const GOV = "0xaa7e0000000000000000000000000000000aa7e0";
  add("C. EVM core", "PAP.owner == 0xaa7e governance",
    (await pap.owner()).toLowerCase() === GOV.toLowerCase(),
    `owner=${await pap.owner()}`);
  add("C. EVM core", "PAP.getACLAdmin == 0xaa7e governance",
    (await pap.getACLAdmin()).toLowerCase() === GOV.toLowerCase());

  const acl = new ethers.Contract(sheet.core.ACLManager, [
    "function isPoolAdmin(address) view returns (bool)",
    "function isRiskAdmin(address) view returns (bool)",
    "function isEmergencyAdmin(address) view returns (bool)",
    "function hasRole(bytes32,address) view returns (bool)",
  ], provider);
  const DEFAULT_ADMIN = "0x" + "0".repeat(64);
  add("C. EVM core", "ACL.isPoolAdmin(0xaa7e)", await acl.isPoolAdmin(GOV));
  add("C. EVM core", "ACL.isRiskAdmin(0xaa7e)", await acl.isRiskAdmin(GOV));
  add("C. EVM core", "ACL.isEmergencyAdmin(0xaa7e)", await acl.isEmergencyAdmin(GOV));
  add("C. EVM core", "ACL.hasRole(DEFAULT_ADMIN_ROLE, 0xaa7e)", await acl.hasRole(DEFAULT_ADMIN, GOV));

  // ===================================================================
  // D. The exact query Max + Juraj would run: getReservesList, getReserveData
  // ===================================================================
  const pool = new ethers.Contract(sheet.core.Pool, [
    "function getReservesList() view returns (address[])",
    "function getReserveData(address) view returns (tuple(tuple(uint256 data) configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
  ], provider);
  const list: string[] = await pool.getReservesList();
  add("D. Reserves (Max/Juraj's path)", "Pool.getReservesList() returns 2 reserves", list.length === 2, JSON.stringify(list));

  const STHDX = sheet.reserves.stHDX.underlying.toLowerCase();
  const HOLLAR = sheet.reserves.HOLLAR.underlying.toLowerCase();
  const lower = list.map(a => a.toLowerCase());
  add("D. Reserves (Max/Juraj's path)", "stHDX present in reserves", lower.includes(STHDX));
  add("D. Reserves (Max/Juraj's path)", "HOLLAR present in reserves", lower.includes(HOLLAR));

  const sthdxRD = await pool.getReserveData(STHDX);
  add("D. Reserves (Max/Juraj's path)", "stHDX.aTokenAddress == sheet.aToken_LockableAToken",
    sthdxRD.aTokenAddress.toLowerCase() === sheet.reserves.stHDX.aToken_LockableAToken.toLowerCase());

  const hollarRD = await pool.getReserveData(HOLLAR);
  add("D. Reserves (Max/Juraj's path)", "HOLLAR.aTokenAddress == sheet.aToken_GhoAToken",
    hollarRD.aTokenAddress.toLowerCase() === sheet.reserves.HOLLAR.aToken_GhoAToken.toLowerCase());
  add("D. Reserves (Max/Juraj's path)", "HOLLAR.variableDebtTokenAddress == sheet",
    hollarRD.variableDebtTokenAddress.toLowerCase() === sheet.reserves.HOLLAR.variableDebtToken.toLowerCase());

  // Decode reserve config: stHDX should be active, not frozen, supply-only
  const sCfg = BigInt(sthdxRD.configuration.data.toString());
  add("D. Reserves (Max/Juraj's path)", "stHDX active",      ((sCfg >> 56n) & 1n) === 1n);
  add("D. Reserves (Max/Juraj's path)", "stHDX not frozen",  ((sCfg >> 57n) & 1n) === 0n);
  add("D. Reserves (Max/Juraj's path)", "stHDX borrowingDisabled", ((sCfg >> 58n) & 1n) === 0n);
  add("D. Reserves (Max/Juraj's path)", "stHDX LTV == 4000bps",      (sCfg & ((1n << 16n) - 1n)) === 4000n);
  add("D. Reserves (Max/Juraj's path)", "stHDX LiqThresh == 7000bps", ((sCfg & (((1n << 16n) - 1n) << 16n)) >> 16n) === 7000n);

  const hCfg = BigInt(hollarRD.configuration.data.toString());
  add("D. Reserves (Max/Juraj's path)", "HOLLAR active",        ((hCfg >> 56n) & 1n) === 1n);
  add("D. Reserves (Max/Juraj's path)", "HOLLAR not frozen",    ((hCfg >> 57n) & 1n) === 0n);
  add("D. Reserves (Max/Juraj's path)", "HOLLAR borrowingEnabled", ((hCfg >> 58n) & 1n) === 1n);

  // ===================================================================
  // E. Token contracts respond to standard ERC20 reads
  // ===================================================================
  for (const [label, addr] of [
    ["stHDX aToken (LockableAToken)", sheet.reserves.stHDX.aToken_LockableAToken],
    ["HOLLAR aToken (GhoAToken)",     sheet.reserves.HOLLAR.aToken_GhoAToken],
    ["HOLLAR variableDebtToken",      sheet.reserves.HOLLAR.variableDebtToken],
  ]) {
    try {
      const t = new ethers.Contract(addr, [
        "function symbol() view returns (string)",
        "function decimals() view returns (uint8)",
        "function totalSupply() view returns (uint256)",
        "function name() view returns (string)",
      ], provider);
      const [sym, dec, ts] = await Promise.all([t.symbol(), t.decimals(), t.totalSupply()]);
      add("E. Token reads", `${label} ERC20 reads`, true, `symbol=${sym} decimals=${dec} totalSupply=${ts.toString()}`);
    } catch (e: any) {
      add("E. Token reads", `${label} ERC20 reads`, false, (e.message || "").slice(0, 60));
    }
  }

  // ===================================================================
  // F. HOLLAR facilitator — the key fix from ref 327
  // ===================================================================
  const hollar = new ethers.Contract(HOLLAR, [
    "function getFacilitator(address) view returns (tuple(uint128 bucketCapacity, uint128 bucketLevel, string label))",
    "function getFacilitatorsList() view returns (address[])",
  ], provider);
  const realGhoAToken = sheet.reserves.HOLLAR.aToken_GhoAToken;
  const fac = await hollar.getFacilitator(realGhoAToken);
  add("F. HOLLAR facilitator (ref 327)", "Real GhoAToken is registered facilitator",
    fac.bucketCapacity.gt(0), `cap=${fac.bucketCapacity.toString()} label="${fac.label}"`);
  add("F. HOLLAR facilitator (ref 327)", "Bucket cap == 1M HOLLAR",
    fac.bucketCapacity.eq(ethers.utils.parseUnits("1.0", 24)),
    `cap=${ethers.utils.formatUnits(fac.bucketCapacity, 18)} HOLLAR`);

  // ===================================================================
  // G. GhoAToken cross-references — the key fix from ref 326
  // ===================================================================
  const ghoAToken = new ethers.Contract(realGhoAToken, [
    "function getVariableDebtToken() view returns (address)",
    "function getGhoTreasury() view returns (address)",
  ], provider);
  const vdAddr = sheet.reserves.HOLLAR.variableDebtToken;
  const treasuryAddr = sheet.core.Treasury;
  const xref1 = await ghoAToken.getVariableDebtToken();
  add("G. GhoAToken cross-refs (ref 326)", "GhoAToken.varDebt == sheet.variableDebt",
    xref1.toLowerCase() === vdAddr.toLowerCase(), `got=${xref1}`);
  const xref2 = await ghoAToken.getGhoTreasury();
  add("G. GhoAToken cross-refs (ref 326)", "GhoAToken.treasury == sheet.Treasury",
    xref2.toLowerCase() === treasuryAddr.toLowerCase(), `got=${xref2}`);

  const vd = new ethers.Contract(vdAddr, [
    "function getAToken() view returns (address)",
    "function getDiscountRateStrategy() view returns (address)",
    "function getDiscountToken() view returns (address)",
  ], provider);
  const xref3 = await vd.getAToken();
  add("G. GhoAToken cross-refs (ref 326)", "VarDebt.aToken == sheet.aToken_GhoAToken",
    xref3.toLowerCase() === realGhoAToken.toLowerCase(), `got=${xref3}`);
  const xref4 = await vd.getDiscountRateStrategy();
  add("G. GhoAToken cross-refs (ref 326)", "VarDebt.discountRateStrategy is non-zero",
    xref4 !== "0x0000000000000000000000000000000000000000", `got=${xref4}`);
  const xref5 = await vd.getDiscountToken();
  add("G. GhoAToken cross-refs (ref 326)", "VarDebt.discountToken == HOLLAR",
    xref5.toLowerCase() === HOLLAR, `got=${xref5}`);

  // ===================================================================
  // H. Oracle
  // ===================================================================
  const oracle = new ethers.Contract(sheet.core.AaveOracle, [
    "function getSourceOfAsset(address) view returns (address)",
    "function getAssetPrice(address) view returns (uint256)",
  ], provider);
  const sthdxOracle = await oracle.getSourceOfAsset(STHDX);
  add("H. Oracle", "stHDX oracle source set",
    sthdxOracle !== "0x0000000000000000000000000000000000000000",
    `source=${sthdxOracle}`);
  try {
    const p = await oracle.getAssetPrice(STHDX);
    add("H. Oracle", "stHDX price returns without revert", p.gt(0), `price=${p.toString()} (= $${(Number(p) / 1e8).toFixed(4)})`);
  } catch (e: any) {
    add("H. Oracle", "stHDX price returns without revert", false, "REVERT");
  }
  try {
    const p = await oracle.getAssetPrice(HOLLAR);
    add("H. Oracle", "HOLLAR price returns without revert", p.gt(0), `price=${p.toString()}`);
  } catch (e: any) {
    add("H. Oracle", "HOLLAR price returns without revert", false, "REVERT");
  }

  // ===================================================================
  // I. EVM precompile (LockManager at 0x0806) — used by LockableAToken
  // ===================================================================
  try {
    const lm = new ethers.Contract("0x0000000000000000000000000000000000000806", [
      "function getLockedBalance(address,address) view returns (uint256)"
    ], provider);
    const lockedZeroAddr = await lm.getLockedBalance(sheet.reserves.stHDX.aToken_LockableAToken, "0x0000000000000000000000000000000000000001");
    add("I. LockManager precompile (0x0806)", "responds to getLockedBalance", true, `returned=${lockedZeroAddr.toString()}`);
  } catch (e: any) {
    add("I. LockManager precompile (0x0806)", "responds to getLockedBalance", false, (e.message || "").slice(0, 60));
  }

  await api.disconnect();

  // ===================================================================
  // Print results, grouped
  // ===================================================================
  console.log("");
  let lastGroup = "";
  for (const r of results) {
    if (r.group !== lastGroup) {
      console.log(`\n${"=".repeat(70)}\n  ${r.group}\n${"=".repeat(70)}`);
      lastGroup = r.group;
    }
    const mark = r.ok ? "✓ PASS" : "✗ FAIL";
    console.log(`  ${mark}  ${r.name}${r.detail ? "\n          " + r.detail : ""}`);
  }
  const passed = results.filter(r => r.ok).length;
  const failed = results.length - passed;
  console.log(`\n${"=".repeat(70)}`);
  console.log(`  ${passed}/${results.length} checks passed${failed ? `, ${failed} FAILED` : ""}`);
  console.log("=".repeat(70));
  if (failed > 0) {
    console.log("\nFailing checks:");
    for (const r of results.filter(r => !r.ok)) {
      console.log(`  - [${r.group}] ${r.name}: ${r.detail}`);
    }
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(`\nVERIFY SCRIPT FAILED: ${e.message}`);
  process.exit(2);
});
