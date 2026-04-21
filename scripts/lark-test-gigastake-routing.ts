// End-to-end test: prove that pallet-gigahdx.gigaStake routes stHDX into the
// NEW GIGAHDX pool (Pool-Proxy-GIGAHDX) and NOT the old Hydration pool.
//
// Strategy:
//   1. Pre-flight: verify on-chain storage (gigaHdxPoolContract) + pallets.
//   2. Snapshot stHDX aToken balances for the tester in BOTH pools (GIGAHDX + Hydration).
//   3. Submit gigaHdx.gigaStake(amount) signed by tester.
//   4. Snapshot aToken balances again and compare deltas.
//   5. Assert: GIGAHDX aToken delta ≈ staked amount, Hydration aToken delta == 0.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";
import { ethers } from "ethers";

const WS_URL = process.env.WS_URL || "wss://1.lark.hydration.cloud";
const RPC_URL = process.env.RPC_URL || "https://1.lark.hydration.cloud";
const TESTER_URI = process.env.TESTER_URI || "//Bob";
const STAKE_HDX = BigInt(process.env.STAKE_HDX || "100") * BigInt(10 ** 12);

const GIGAHDX_POOL = "0x3d2e0116373610dD215d86080Ca79f417311F014";
const HYDRATION_POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const STHDX = "0x000000000000000000000000000000010000029e";

function section(s: string) {
  console.log("\n" + "=".repeat(70));
  console.log("  " + s);
  console.log("=".repeat(70));
}

async function getReserveAToken(provider: ethers.providers.JsonRpcProvider, poolAddr: string): Promise<string | null> {
  const abi = [
    "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
  ];
  const pool = new ethers.Contract(poolAddr, abi, provider);
  try {
    const d = await pool.getReserveData(STHDX);
    if (d.aTokenAddress === ethers.constants.AddressZero) return null;
    return d.aTokenAddress;
  } catch {
    return null;
  }
}

async function balanceOf(provider: ethers.providers.JsonRpcProvider, token: string, user: string): Promise<bigint> {
  const erc20 = new ethers.Contract(token, ["function balanceOf(address) view returns (uint256)"], provider);
  const b = await erc20.balanceOf(user);
  return b.toBigInt();
}

async function signAndWait(tx: any, signer: any, api: ApiPromise, label: string): Promise<any[]> {
  console.log(`\n-- ${label} --`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }: any) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
          }
          return reject(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
          }
        }
        console.log(`  OK (finalized: ${status.asFinalized.toHex().slice(0, 18)}...)`);
        resolve(events);
      }
    }).catch(reject);
  });
}

async function main() {
  const api = await ApiPromise.create({ provider: new WsProvider(WS_URL) });
  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);

  section("PRE-FLIGHT");

  // Runtime spec
  const ver = await api.rpc.state.getRuntimeVersion();
  console.log(`specVersion: ${ver.specVersion}`);
  if (ver.specVersion.toNumber() < 406) throw new Error("runtime not upgraded — specVersion < 406");

  // Pallets present
  const metadata = await api.rpc.state.getMetadata();
  const pallets = metadata.asLatest.pallets.map((p: any) => p.name.toString());
  for (const need of ["GigaHdx", "GigaHdxVoting", "FeeProcessor"]) {
    if (!pallets.includes(need)) throw new Error(`missing pallet: ${need}`);
  }
  console.log(`pallets present: GigaHdx, GigaHdxVoting, FeeProcessor ✓`);

  // Storage: gigaHdxPoolContract must equal GIGAHDX_POOL
  const gp: any = await api.query.liquidation.gigaHdxPoolContract();
  console.log(`gigaHdxPoolContract: ${gp.toString()}`);
  if (gp.toString().toLowerCase() !== GIGAHDX_POOL.toLowerCase()) {
    throw new Error(`gigaHdxPoolContract is ${gp.toString()}, expected ${GIGAHDX_POOL}`);
  }

  // Tester
  const keyring = new Keyring({ type: "sr25519" });
  const tester = keyring.addFromUri(TESTER_URI);
  const testerEvm = "0x" + u8aToHex(tester.publicKey).slice(2, 42);
  console.log(`tester: ${TESTER_URI} sub=${tester.address} evm=${testerEvm}`);

  const acct: any = await api.query.system.account(tester.address);
  const freeHdx = acct.data.free.toBigInt();
  const frozen = acct.data.frozen.toBigInt();
  const usable = freeHdx > frozen ? freeHdx - frozen : 0n;
  console.log(`tester HDX: free=${freeHdx} frozen=${frozen} usable=${usable}`);
  console.log(`planned stake: ${STAKE_HDX} (${Number(STAKE_HDX / 10n ** 12n)} HDX)`);
  if (usable < STAKE_HDX + BigInt(10 * 10 ** 12)) {
    throw new Error(`tester doesn't have enough usable HDX (need ${STAKE_HDX + BigInt(10 * 10 ** 12)}, have ${usable})`);
  }

  // Resolve stHDX aToken in both pools
  const gigaAToken = await getReserveAToken(provider, GIGAHDX_POOL);
  const hydraAToken = await getReserveAToken(provider, HYDRATION_POOL);
  console.log(`GIGAHDX pool stHDX aToken:   ${gigaAToken || "—"}`);
  console.log(`Hydration pool stHDX aToken: ${hydraAToken || "—"}`);
  if (!gigaAToken) throw new Error("GIGAHDX pool has no stHDX reserve");

  section("SNAPSHOT: tester aToken balances BEFORE stake");
  const beforeGiga = await balanceOf(provider, gigaAToken, testerEvm);
  const beforeHydra = hydraAToken ? await balanceOf(provider, hydraAToken, testerEvm) : 0n;
  console.log(`GIGAHDX aToken balance: ${beforeGiga}`);
  console.log(`Hydration aToken balance: ${beforeHydra}`);

  // Also track Bob's GIGAHDX token (substrate asset 67) just for fun
  let beforeGigaAsset = 0n;
  try {
    const t: any = await api.query.tokens.accounts(tester.address, 67);
    beforeGigaAsset = t.free.toBigInt();
  } catch {}
  console.log(`GIGAHDX asset (67) balance: ${beforeGigaAsset}`);

  section("ACTION: gigaHdx.gigaStake");
  const stakeTx = api.tx.gigaHdx.gigaStake(STAKE_HDX.toString());
  await signAndWait(stakeTx, tester, api, `gigaHdx.gigaStake(${STAKE_HDX})`);

  // Wait a block or two for indexing
  await new Promise((r) => setTimeout(r, 6000));

  section("SNAPSHOT: tester aToken balances AFTER stake");
  const afterGiga = await balanceOf(provider, gigaAToken, testerEvm);
  const afterHydra = hydraAToken ? await balanceOf(provider, hydraAToken, testerEvm) : 0n;
  let afterGigaAsset = 0n;
  try {
    const t: any = await api.query.tokens.accounts(tester.address, 67);
    afterGigaAsset = t.free.toBigInt();
  } catch {}
  console.log(`GIGAHDX aToken balance: ${afterGiga}`);
  console.log(`Hydration aToken balance: ${afterHydra}`);
  console.log(`GIGAHDX asset (67) balance: ${afterGigaAsset}`);

  section("DELTAS + ASSERTION");
  const deltaGiga = afterGiga - beforeGiga;
  const deltaHydra = afterHydra - beforeHydra;
  const deltaGigaAsset = afterGigaAsset - beforeGigaAsset;

  console.log(`GIGAHDX aToken Δ:   ${deltaGiga}  (${Number(deltaGiga) / 1e12} stHDX)`);
  console.log(`Hydration aToken Δ: ${deltaHydra}  (${Number(deltaHydra) / 1e12} stHDX)`);
  console.log(`GIGAHDX asset Δ:    ${deltaGigaAsset}  (substrate-side tracking)`);

  const routedToGigaHdx = deltaGiga > 0n && deltaHydra === 0n;
  const routedToHydration = deltaHydra > 0n;

  console.log("");
  if (routedToGigaHdx) {
    console.log("✓✓✓  STAKE ROUTED TO GIGAHDX POOL — fix confirmed end-to-end");
  } else if (routedToHydration) {
    console.log("✗✗✗  STAKE ROUTED TO OLD HYDRATION POOL — fix NOT working");
    await api.disconnect();
    process.exit(2);
  } else {
    console.log("⚠    neither pool received collateral — something unexpected happened");
    await api.disconnect();
    process.exit(3);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(`\nFAILED: ${e.message}`);
  process.exit(1);
});
