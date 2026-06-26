// Post-proposal state check against a forked BIL market on chopsticks/lark2.
// Run via: HARDHAT_NETWORK=lark2 RPC=ws://localhost:8000 \
//   npx hardhat run scripts/verify-bil-state.ts --network lark2
//
// HARDHAT_NETWORK governs the deployments dir + Ethers JsonRpcProvider; we
// override the WS endpoint for substrate queries.
import { ApiPromise, WsProvider } from "@polkadot/api";
import hre from "hardhat";

const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const DCL_PRECOMPILE = "0x0000000000000000000000000000000100000226"; // asset 550

function fmt(b: any): string {
  return typeof b === "string" ? b : b?.toString?.() ?? String(b);
}

async function main() {
  const PROPOSAL_WS = process.env.PROPOSAL_WS || "ws://localhost:8000";
  const hhre = hre as any;
  const eth = hhre.ethers;

  // ----- Deployments -----
  const pool = await eth.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address) view returns (tuple(tuple(uint256) configuration, uint128 liquidityIndex,uint128 currentLiquidityRate,uint128 variableBorrowIndex,uint128 currentVariableBorrowRate,uint128 currentStableBorrowRate,uint40 lastUpdateTimestamp,uint16 id,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint128 accruedToTreasury,uint128 unbacked,uint128 isolationModeTotalDebt))",
      "function getConfiguration(address) view returns (tuple(uint256))",
    ],
    (await hhre.deployments.get("Pool-Proxy-BIL")).address
  );
  const oracle = await eth.getContractAt(
    ["function getAssetPrice(address) view returns (uint256)"],
    (await hhre.deployments.get("AaveOracle-BIL")).address
  );
  const dataProvider = await eth.getContractAt(
    [
      "function getReserveConfigurationData(address) view returns (uint256 decimals,uint256 ltv,uint256 liquidationThreshold,uint256 liquidationBonus,uint256 reserveFactor,bool usageAsCollateralEnabled,bool borrowingEnabled,bool stableBorrowRateEnabled,bool isActive,bool isFrozen)",
      "function getReserveCaps(address) view returns (uint256 borrowCap, uint256 supplyCap)",
      "function getLiquidationProtocolFee(address) view returns (uint256)",
    ],
    (await hhre.deployments.get("PoolDataProvider-BIL")).address
  );
  const acl = await eth.getContractAt(
    ["function isPoolAdmin(address) view returns (bool)", "function isEmergencyAdmin(address) view returns (bool)"],
    (await hhre.deployments.get("ACLManager-BIL")).address
  );
  const hollar = await eth.getContractAt(
    [
      "function getFacilitator(address) view returns (tuple(uint128 bucketCapacity, uint128 bucketLevel, string label))",
    ],
    HOLLAR
  );

  // ----- EVM CHECKS -----
  console.log("\n=== EVM state ===");
  const reserves: string[] = await pool.getReservesList();
  console.log(`reserves (${reserves.length}):`, reserves);
  const hasDcl = reserves.map((a) => a.toLowerCase()).includes(DCL_PRECOMPILE.toLowerCase());
  const hasHollar = reserves.map((a) => a.toLowerCase()).includes(HOLLAR.toLowerCase());
  console.log(`  BIL    initialized: ${hasDcl ? "✓" : "✗"}`);
  console.log(`  HOLLAR initialized: ${hasHollar ? "✓" : "✗"}`);

  if (hasDcl) {
    const cfg = await dataProvider.getReserveConfigurationData(DCL_PRECOMPILE);
    const caps = await dataProvider.getReserveCaps(DCL_PRECOMPILE);
    const liqFee = await dataProvider.getLiquidationProtocolFee(DCL_PRECOMPILE);
    const dclData = await pool.getReserveData(DCL_PRECOMPILE);
    const price = await oracle.getAssetPrice(DCL_PRECOMPILE).catch(() => "(oracle reverted)");
    console.log(`\nDCL reserve:`);
    console.log(`  aToken:          ${dclData.aTokenAddress}`);
    console.log(`  ltv:             ${fmt(cfg.ltv)} (want 7000)`);
    console.log(`  liqThreshold:    ${fmt(cfg.liquidationThreshold)} (want 8000)`);
    console.log(`  liqBonus:        ${fmt(cfg.liquidationBonus)}`);
    console.log(`  reserveFactor:   ${fmt(cfg.reserveFactor)}`);
    console.log(`  supplyCap:       ${fmt(caps.supplyCap)} (want 3_000_000)`);
    console.log(`  borrowCap:       ${fmt(caps.borrowCap)}`);
    console.log(`  borrowing:       ${cfg.borrowingEnabled} (want false)`);
    console.log(`  collateral:      ${cfg.usageAsCollateralEnabled} (want true)`);
    console.log(`  active/frozen:   ${cfg.isActive}/${cfg.isFrozen}`);
    console.log(`  liqProtocolFee:  ${fmt(liqFee)} (want 1000=10%)`);
    console.log(`  price (oracle):  ${fmt(price)}`);
  }
  if (hasHollar) {
    const cfg = await dataProvider.getReserveConfigurationData(HOLLAR);
    const caps = await dataProvider.getReserveCaps(HOLLAR);
    const data = await pool.getReserveData(HOLLAR);
    const price = await oracle.getAssetPrice(HOLLAR).catch(() => "(oracle reverted)");
    console.log(`\nHOLLAR reserve:`);
    console.log(`  aToken:          ${data.aTokenAddress}`);
    console.log(`  variableDebt:    ${data.variableDebtTokenAddress}`);
    console.log(`  borrowing:       ${cfg.borrowingEnabled} (want true)`);
    console.log(`  collateral:      ${cfg.usageAsCollateralEnabled} (want false)`);
    console.log(`  active/frozen:   ${cfg.isActive}/${cfg.isFrozen}`);
    console.log(`  supplyCap:       ${fmt(caps.supplyCap)}`);
    console.log(`  price (oracle):  ${fmt(price)}`);

    // Facilitator check on HOLLAR token side.
    const fac = await hollar.getFacilitator(data.aTokenAddress);
    console.log(`\nHOLLAR facilitator for ${data.aTokenAddress}:`);
    console.log(`  label:        ${fac.label}`);
    console.log(`  bucketCapacity: ${fmt(fac.bucketCapacity)} (want 1_000_000 * 1e18)`);
    console.log(`  bucketLevel:    ${fmt(fac.bucketLevel)}`);
  }

  // ACL — make sure ownership + roles are sane after proposal (was set before via transfer-protocol-ownership).
  console.log("\nACL spot checks:");
  console.log(`  precompile (aa7e0) isPoolAdmin:      ${await acl.isPoolAdmin("0xaa7e0000000000000000000000000000000aa7e0")}`);
  console.log(`  precompile (aa7e0) isEmergencyAdmin: ${await acl.isEmergencyAdmin("0xaa7e0000000000000000000000000000000aa7e0")}`);
  console.log(`  Alice              isPoolAdmin:      ${await acl.isPoolAdmin("0x222222B60cA97a4998B7D07b99034Fa4d9339531")}`);

  // PoolAddressesProviderRegistry — confirm BIL is registered.
  const reg = await eth.getContractAt(
    [
      "function getAddressesProviderIdByAddress(address) view returns (uint256)",
      "function getAddressesProvidersList() view returns (address[])",
    ],
    (await hhre.deployments.get("PoolAddressesProviderRegistry")).address
  );
  const provider = (await hhre.deployments.get("PoolAddressesProvider-BIL")).address;
  const id = await reg.getAddressesProviderIdByAddress(provider);
  const list = await reg.getAddressesProvidersList();
  console.log(`\nProviderRegistry:`);
  console.log(`  BIL provider ${provider} -> id ${fmt(id)} (want 22222255)`);
  console.log(`  total providers: ${list.length}`);

  // ----- SUBSTRATE CHECKS -----
  const api = await ApiPromise.create({ provider: new WsProvider(PROPOSAL_WS) });
  console.log(`\n=== Substrate state (${PROPOSAL_WS}) ===`);

  for (const [id, label] of [[550, "BIL"], [55, "BIL"]] as [number, string][]) {
    const info: any = await api.query.assetRegistry.assets(id);
    const loc: any = await api.query.assetRegistry.assetLocations(id);
    const fee: any = await api.query.multiTransactionPayment.acceptedCurrencies(id);
    const locAddr =
      loc.isSome ? (loc.toHuman() as any)?.interior?.X1?.[0]?.AccountKey20?.key : null;
    console.log(`\nasset ${id} (${label}):`);
    console.log(`  registered:    ${info.isSome}`);
    if (info.isSome) {
      const j: any = info.toHuman();
      console.log(`    type=${j.assetType} symbol=${j.symbol} decimals=${j.decimals} isSufficient=${j.isSufficient}`);
    }
    console.log(`  location:      ${locAddr ?? "(none)"}`);
    console.log(`  fee currency:  ${fee.isSome}${fee.isSome ? " (price=" + fmt(fee.toHuman()) + ")" : ""}`);
  }

  // evmAccounts.approveContract for Pool-Proxy-BIL
  const poolProxyAddr = (await hhre.deployments.get("Pool-Proxy-BIL")).address;
  const evmAccountsQ: any = (api.query as any).evmAccounts ?? (api.query as any).eVMAccounts;
  const approved: any = await evmAccountsQ.approvedContract(poolProxyAddr);
  console.log(`\nevmAccounts.approvedContract(${poolProxyAddr}):`);
  console.log(`  approved: ${approved.isSome}`);

  await api.disconnect();
  console.log("\nDone.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
