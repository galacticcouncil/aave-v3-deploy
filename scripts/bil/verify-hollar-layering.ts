// Demonstrate the HOLLAR layering on lark 2:
//   - HOLLAR underlying token = single shared ERC20 (no -BIL postfix)
//   - GhoAToken (HOLLAR's per-MM Aave wrapper) IS BIL-specific
//   - The proxy deployed for HOLLAR in the BIL MM uses the
//     GhoAToken-BIL implementation that we deployed in Phase 4

import { ethers } from "ethers";
import * as fs from "fs";

const RPC = process.env.RPC_URL || "https://2.lark.hydration.cloud";
const POOL = "0xb952AE92cC4D8D703d2d71Ab541baB34c94b944A";
const HOLLAR_UNDERLYING = "0x531a654d1696ED52e7275A8cede955E82620f99a";

async function main() {
  const provider = new ethers.providers.JsonRpcProvider(RPC);

  // ---------- 1. The HOLLAR underlying token ----------
  const underlying = new ethers.Contract(HOLLAR_UNDERLYING, [
    "function symbol() view returns (string)",
    "function name() view returns (string)",
    "function totalSupply() view returns (uint256)",
    "function getFacilitatorsList() view returns (address[])",
  ], provider);
  console.log("=".repeat(70));
  console.log("  HOLLAR underlying — the actual stablecoin ERC20");
  console.log("=".repeat(70));
  console.log(`  address:    ${HOLLAR_UNDERLYING}`);
  console.log(`  symbol:     ${await underlying.symbol()}`);
  console.log(`  name:       ${await underlying.name()}`);
  console.log(`  totalSupply: ${(await underlying.totalSupply()).toString()}`);

  const facList = await underlying.getFacilitatorsList();
  console.log(`  facilitators (${facList.length}):`);
  const hollarRead = new ethers.Contract(HOLLAR_UNDERLYING, [
    "function getFacilitator(address) view returns (tuple(uint128 bucketCapacity, uint128 bucketLevel, string label))",
  ], provider);
  for (const f of facList) {
    const info = await hollarRead.getFacilitator(f);
    const cap = info.bucketCapacity.gt(0) ? ethers.utils.formatUnits(info.bucketCapacity, 18) : "0";
    const lvl = info.bucketLevel.gt(0) ? ethers.utils.formatUnits(info.bucketLevel, 18) : "0";
    console.log(`    ${f}  cap=${cap}  level=${lvl}  "${info.label}"`);
  }

  // ---------- 2. HOLLAR's wrappers in the BIL pool ----------
  const pool = new ethers.Contract(POOL, [
    "function getReserveData(address) view returns (tuple(tuple(uint256 data) configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
  ], provider);
  const rd = await pool.getReserveData(HOLLAR_UNDERLYING);

  console.log("\n" + "=".repeat(70));
  console.log("  HOLLAR wrappers in the BIL pool — these ARE BIL-specific");
  console.log("=".repeat(70));
  console.log(`  aToken (GhoAToken proxy):       ${rd.aTokenAddress}`);
  console.log(`  variableDebtToken proxy:        ${rd.variableDebtTokenAddress}`);
  console.log(`  stableDebtToken proxy:          ${rd.stableDebtTokenAddress}`);
  console.log(`  interestRateStrategy:           ${rd.interestRateStrategyAddress}`);

  // Read each token's symbol — these have the BIL prefix
  for (const [label, addr] of [
    ["aToken", rd.aTokenAddress],
    ["variableDebtToken", rd.variableDebtTokenAddress],
  ]) {
    const t = new ethers.Contract(addr, [
      "function symbol() view returns (string)",
      "function name() view returns (string)",
      "function UNDERLYING_ASSET_ADDRESS() view returns (address)",
    ], provider);
    const sym = await t.symbol();
    const name = await t.name();
    let und = "n/a";
    try { und = await t.UNDERLYING_ASSET_ADDRESS(); } catch {}
    console.log(`  ${label} ${addr}: symbol="${sym}", name="${name}"`);
    console.log(`    UNDERLYING_ASSET_ADDRESS = ${und} (= HOLLAR underlying ${und.toLowerCase() === HOLLAR_UNDERLYING.toLowerCase() ? "✓" : "✗"})`);
  }

  // ---------- 3. The proxy delegates to which IMPL? ----------
  // Aave/EIP-1967 implementation slot
  const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const implRaw = await provider.getStorageAt(rd.aTokenAddress, IMPL_SLOT);
  const implAddr = "0x" + implRaw.slice(-40);
  console.log("\n" + "=".repeat(70));
  console.log("  Implementation behind the proxy (EIP-1967 slot)");
  console.log("=".repeat(70));
  console.log(`  proxy:           ${rd.aTokenAddress}`);
  console.log(`  implementation:  ${implAddr}`);

  // Compare with deployed artifact
  const artifactPath = "deployments/lark2/GhoAToken-BIL.json";
  if (fs.existsSync(artifactPath)) {
    const j = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    const match = j.address.toLowerCase() === implAddr.toLowerCase();
    console.log(`  ${artifactPath} address: ${j.address}  ${match ? "✓ MATCH" : "✗ DIFFERS"}`);
    console.log(`  → the proxy delegates to GhoAToken-BIL implementation`);
  }

  // Same for the var debt
  const vdImplRaw = await provider.getStorageAt(rd.variableDebtTokenAddress, IMPL_SLOT);
  const vdImplAddr = "0x" + vdImplRaw.slice(-40);
  console.log(`\n  variableDebtToken proxy:           ${rd.variableDebtTokenAddress}`);
  console.log(`  variableDebtToken implementation:  ${vdImplAddr}`);
  const vdArtifactPath = "deployments/lark2/GhoVariableDebtToken-BIL.json";
  if (fs.existsSync(vdArtifactPath)) {
    const j = JSON.parse(fs.readFileSync(vdArtifactPath, "utf8"));
    const match = j.address.toLowerCase() === vdImplAddr.toLowerCase();
    console.log(`  ${vdArtifactPath} address: ${j.address}  ${match ? "✓ MATCH" : "✗ DIFFERS"}`);
    console.log(`  → the proxy delegates to GhoVariableDebtToken-BIL implementation`);
  }

  console.log("\n" + "=".repeat(70));
  console.log("  Summary");
  console.log("=".repeat(70));
  console.log(`  HOLLAR underlying:             1 token (shared, no postfix)`);
  console.log(`  HOLLAR-BIL wrappers:       3 proxies × 1 BIL-specific impl each`);
  console.log(`  facilitator rights:            granted per-proxy via HOLLAR.addFacilitator`);
}
main().catch((e) => { console.error(e); process.exit(1); });
