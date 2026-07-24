// End-to-end test for BIL on lark 1.
//
// Exercises the full user journey and reports which phases pass, which fail,
// and why. Designed to be re-run as upstream blockers (oracle, pallet bugs)
// are resolved — phases auto-skip dependencies on failure.
//
// Phases:
//   1. Preflight:   spec ≥ 406, required pallets, bilPoolContract, balance
//   2. Oracle:      getAssetPrice(stHDX), getAssetPrice(HOLLAR)
//   3. Supply:      bil.gigaStake → aBILstHDX mint
//   4. Borrow:      Pool.borrow(HOLLAR) via evm.call
//   5. Repay:       HOLLAR.approve + Pool.repay via evm.call
//   6. Withdraw:    Pool.withdraw(stHDX) via evm.call
//   7. Transfer:    aBILstHDX.transfer (LockableAToken free path)
//
// Usage:
//   WS_URL=wss://2.lark.hydration.cloud npx ts-node scripts/bil/test-e2e.ts
//   TESTER_URI=//Bob STAKE_HDX=200 npx ts-node scripts/bil/test-e2e.ts

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const WS_URL = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const RPC_URL = process.env.RPC_URL || "https://2.lark.hydration.cloud";
const TESTER_URI = process.env.TESTER_URI || "//Bob";
const STAKE_HDX = BigInt(process.env.STAKE_HDX || "200") * BigInt(10 ** 12);

// Auto-resolve POOL + ORACLE from deployments/lark2/. A_STHDX + VD_HOLLAR are
// AAVE-managed proxies created during Phase 7 reserve init — query them from
// Pool.getReserveData(asset) at runtime instead of relying on static artifacts.
function readDeployment(name: string): string {
	if (process.env[name.toUpperCase().replace(/-/g, "_")]) return process.env[name.toUpperCase().replace(/-/g, "_")]!;
	const p = path.join(__dirname, "..", "..", "deployments", "lark2", `${name}.json`);
	if (!fs.existsSync(p)) throw new Error(`missing artifact: ${p}`);
	return JSON.parse(fs.readFileSync(p, "utf8")).address;
}
const POOL = process.env.POOL || readDeployment("Pool-Proxy-BIL");
const ORACLE = process.env.ORACLE || readDeployment("AaveOracle-BIL");
const STHDX = "0x000000000000000000000000000000010000029e";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";

type Status = "pass" | "fail" | "skip";
const results: Array<{ phase: string; status: Status; note: string }> = [];

function section(s: string) {
  console.log("\n" + "=".repeat(72));
  console.log("  " + s);
  console.log("=".repeat(72));
}

async function phase(label: string, fn: () => Promise<string>): Promise<boolean> {
  section(label);
  try {
    const note = await fn();
    console.log(`\n  PASS — ${note}`);
    results.push({ phase: label, status: "pass", note });
    return true;
  } catch (e: any) {
    const msg = e.message || String(e);
    const status: Status = msg.startsWith("SKIP:") ? "skip" : "fail";
    console.log(`\n  ${status.toUpperCase()} — ${msg.replace(/^SKIP:\s*/, "")}`);
    results.push({ phase: label, status, note: msg.replace(/^SKIP:\s*/, "") });
    return false;
  }
}

async function signAndWait(tx: any, signer: any, api: ApiPromise, label: string): Promise<any[]> {
  console.log(`  tx: ${label}`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }: any) => {
      if (status.isInBlock) console.log(`    in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (!status.isFinalized) return;
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
        if (event.section === "ethereum" && event.method === "Executed") {
          const data: any = event.data.toJSON();
          const exitReason = data[3];
          if (exitReason && typeof exitReason === "object") {
            if ("revert" in exitReason) return reject(new Error(`EVM revert: ${JSON.stringify(exitReason.revert).slice(0, 200)}`));
            if ("error" in exitReason) return reject(new Error(`EVM error: ${JSON.stringify(exitReason.error)}`));
            if ("fatal" in exitReason) return reject(new Error(`EVM fatal: ${JSON.stringify(exitReason.fatal)}`));
          }
        }
        if (event.section === "evm" && (event.method === "ExecutedFailed" || event.method === "Failed")) {
          return reject(new Error(`evm.${event.method}: ${event.data.toString().slice(0, 200)}`));
        }
      }
      console.log(`    finalized: ${status.asFinalized.toHex().slice(0, 18)}...`);
      resolve(events);
    }).catch(reject);
  });
}

async function balanceOf(provider: ethers.providers.JsonRpcProvider, token: string, user: string): Promise<bigint> {
  const c = new ethers.Contract(token, ["function balanceOf(address) view returns (uint256)"], provider);
  return (await c.balanceOf(user)).toBigInt();
}

async function callEvm(
  api: ApiPromise,
  signer: any,
  source: string,
  target: string,
  data: string,
  label: string
): Promise<any[]> {
  // Reduced from (3_000_000, 1_000_000_000) to (1_000_000, 100_000_000) to rule out
  // EVM balance check failures. At Hydration's 1.5 Mwei gas price, 1M × 0.1 Gwei
  // (100 Mwei) is still 66× the minimum effective price.
  const tx: any = (api.tx as any).evm.call(
    source,
    target,
    data,
    "0",
    1_000_000,
    "100000000",
    null,
    null,
    [],
    []
  );
  return signAndWait(tx, signer, api, label);
}

async function main() {
  const api = await ApiPromise.create({ provider: new WsProvider(WS_URL) });
  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const keyring = new Keyring({ type: "sr25519" });
  const tester = keyring.addFromUri(TESTER_URI);
  const testerEvm = "0x" + u8aToHex(tester.publicKey).slice(2, 42);

  console.log(`chain:  ${WS_URL}`);
  console.log(`tester: ${TESTER_URI} sub=${tester.address} evm=${testerEvm}`);

  // Resolve aToken + variable-debt-token proxies from Pool.getReserveData. These
  // proxies are created during Phase 7 reserve init and don't have static artifacts.
  const poolReader = new ethers.Contract(
    POOL,
    [
      "function getReserveData(address) view returns (tuple(tuple(uint256 data) configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
    ],
    provider
  );
  const stHdxData = await poolReader.getReserveData(STHDX);
  const hollarData = await poolReader.getReserveData(HOLLAR);
  const A_STHDX = stHdxData.aTokenAddress;
  const VD_HOLLAR = hollarData.variableDebtTokenAddress;
  console.log(`A_STHDX:   ${A_STHDX}`);
  console.log(`VD_HOLLAR: ${VD_HOLLAR}`);
  if (A_STHDX === ethers.constants.AddressZero) throw new Error("stHDX reserve not initialized in Pool — Phase 7 incomplete?");
  if (VD_HOLLAR === ethers.constants.AddressZero) throw new Error("HOLLAR reserve not initialized in Pool — Phase 7 incomplete?");

  let supplyAToken = 0n;
  let hollarDebt = 0n;
  let oracleStHdxWorks = false;

  // -------------- Phase 1 --------------
  await phase("1. Preflight", async () => {
    const ver = await api.rpc.state.getRuntimeVersion();
    if (ver.specVersion.toNumber() < 406) throw new Error(`specVersion=${ver.specVersion.toNumber()} < 406`);

    const metadata = await api.rpc.state.getMetadata();
    const pallets = metadata.asLatest.pallets.map((p: any) => p.name.toString());
    // Pivot 2026-05-06: BilVoting + FeeProcessor were dropped from the runtime.
    // Bil is the only required pallet now.
    for (const p of ["Bil"]) {
      if (!pallets.includes(p)) throw new Error(`missing pallet: ${p}`);
    }

    const gp: any = await api.query.bil.bilPoolContract();
    if (gp.toString().toLowerCase() !== POOL.toLowerCase()) {
      throw new Error(`bil.bilPoolContract=${gp} expected=${POOL}`);
    }

    const acct: any = await api.query.system.account(tester.address);
    const usable = acct.data.free.toBigInt() - acct.data.frozen.toBigInt();
    const needed = STAKE_HDX + BigInt(10 * 10 ** 12);
    if (usable < needed) throw new Error(`insufficient HDX: usable=${usable} need=${needed}`);

    return `spec=${ver.specVersion.toNumber()}, pallets OK, pool wired, usable=${usable / 10n ** 12n} HDX`;
  });

  // -------------- Phase 2 --------------
  await phase("2. Oracle prices", async () => {
    const oracle = new ethers.Contract(ORACLE, ["function getAssetPrice(address) view returns (uint256)"], provider);
    let st: string;
    let ho: string;
    try {
      st = (await oracle.getAssetPrice(STHDX)).toString();
      oracleStHdxWorks = true;
    } catch (e: any) {
      st = `REVERT`;
    }
    try {
      ho = (await oracle.getAssetPrice(HOLLAR)).toString();
    } catch {
      ho = `REVERT`;
    }
    console.log(`  stHDX  price: ${st}`);
    console.log(`  HOLLAR price: ${ho}`);
    if (!oracleStHdxWorks) {
      throw new Error(`stHDX oracle reverts — borrow & withdraw-with-debt will fail downstream`);
    }
    return `stHDX=${st}, HOLLAR=${ho}`;
  });

  // -------------- Phase 3 --------------
  const suppliedOk = await phase("3. Supply (via bil.gigaStake)", async () => {
    const before = await balanceOf(provider, A_STHDX, testerEvm);
    await signAndWait(api.tx.bil.gigaStake(STAKE_HDX.toString()), tester, api, `gigaStake(${STAKE_HDX})`);
    await new Promise((r) => setTimeout(r, 6000));
    const after = await balanceOf(provider, A_STHDX, testerEvm);
    supplyAToken = after - before;
    if (supplyAToken === 0n) throw new Error(`aToken balance did not change`);
    return `aBILstHDX Δ = +${supplyAToken} (~${Number(supplyAToken) / 1e12} stHDX)`;
  });

  // -------------- Phase 4 --------------
  await phase("4. Borrow HOLLAR (Pool.borrow via evm.call)", async () => {
    if (!suppliedOk) throw new Error(`SKIP: supply phase failed — no collateral`);
    if (!oracleStHdxWorks) throw new Error(`SKIP: stHDX oracle blocked — cannot value collateral`);

    const iface = new ethers.utils.Interface(["function borrow(address,uint256,uint256,uint16,address)"]);
    // Collateral ~ 17 stHDX × $0.0107 ≈ $0.18; LTV 40% → max borrow ≈ $0.073.
    // Borrow 0.05 HOLLAR (= $0.05) to stay well inside HF.
    const amt = ethers.utils.parseUnits("0.05", 18);
    const data = iface.encodeFunctionData("borrow", [HOLLAR, amt, 2, 0, testerEvm]);

    const hBefore = await balanceOf(provider, HOLLAR, testerEvm);
    const dBefore = await balanceOf(provider, VD_HOLLAR, testerEvm);
    await callEvm(api, tester, testerEvm, POOL, data, `Pool.borrow(0.05 HOLLAR)`);
    await new Promise((r) => setTimeout(r, 6000));
    const hAfter = await balanceOf(provider, HOLLAR, testerEvm);
    const dAfter = await balanceOf(provider, VD_HOLLAR, testerEvm);

    hollarDebt = dAfter - dBefore;
    const gotHollar = hAfter - hBefore;
    if (gotHollar === 0n) throw new Error(`HOLLAR balance did not change — facilitator mint likely failed`);
    return `HOLLAR Δ=+${gotHollar}, vdHOLLAR Δ=+${hollarDebt}`;
  });

  // -------------- Phase 5 --------------
  await phase("5. Repay HOLLAR", async () => {
    if (hollarDebt === 0n) throw new Error(`SKIP: no outstanding debt`);

    // Debt accrues interest between borrow and repay blocks, so current debt
    // is slightly larger than our HOLLAR balance. Repay what Bob actually has.
    const hollarBal = await balanceOf(provider, HOLLAR, testerEvm);
    if (hollarBal === 0n) throw new Error(`SKIP: Bob has no HOLLAR to repay with`);

    const approveIface = new ethers.utils.Interface(["function approve(address,uint256)"]);
    const repayIface = new ethers.utils.Interface(["function repay(address,uint256,uint256,address)"]);

    await callEvm(api, tester, testerEvm, HOLLAR, approveIface.encodeFunctionData("approve", [POOL, hollarBal]), `HOLLAR.approve(${hollarBal})`);
    await callEvm(api, tester, testerEvm, POOL, repayIface.encodeFunctionData("repay", [HOLLAR, hollarBal, 2, testerEvm]), `Pool.repay(${hollarBal})`);
    await new Promise((r) => setTimeout(r, 6000));
    const dAfter = await balanceOf(provider, VD_HOLLAR, testerEvm);
    return `repaid ${hollarBal}; vdHOLLAR residual = ${dAfter} (interest dust)`;
  });

  // -------------- Phase 6 --------------
  // Pivot 2026-05-06: BIL is non-transferable by design. Pool.withdraw on the
  // aToken always reverts with ExceedsFreeBalance because the LockManager precompile
  // reports the user's full aToken balance as locked. The supported unstake path is
  // the bil pallet extrinsic, which burns the aToken and creates a pendingUnstake
  // position with a cooldown.
  await phase("6. Unstake (via bil.gigaUnstake)", async () => {
    if (!suppliedOk) throw new Error(`SKIP: no supply`);

    const aBefore = await balanceOf(provider, A_STHDX, testerEvm);
    const amt = supplyAToken / 10n; // unstake 10%
    const tx = api.tx.bil.gigaUnstake(amt.toString());
    console.log(`  tx: gigaUnstake(${amt})`);
    await new Promise<void>((res, rej) => {
      tx.signAndSend(tester, ({ status, dispatchError, events }) => {
        if (status.isInBlock) console.log(`    in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
        if (status.isFinalized) {
          if (dispatchError) {
            if (dispatchError.isModule) {
              const d = api.registry.findMetaError(dispatchError.asModule);
              return rej(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
            }
            return rej(new Error(dispatchError.toString()));
          }
          for (const { event } of events) {
            if (event.section === "system" && event.method === "ExtrinsicFailed") return rej(new Error(`ExtrinsicFailed: ${event.data}`));
          }
          console.log(`    finalized: ${status.asFinalized.toHex().slice(0, 18)}...`);
          res();
        }
      }).catch(rej);
    });
    await new Promise((r) => setTimeout(r, 6000));
    const aAfter = await balanceOf(provider, A_STHDX, testerEvm);
    const delta = aBefore - aAfter;
    if (delta === 0n) throw new Error(`aToken balance unchanged — unstake silently failed`);
    const pending: any = await api.query.bil.pendingUnstakes(tester.address);
    return `aToken Δ = -${delta}; pendingUnstakes = ${pending.toString()}`;
  });

  // -------------- Phase 7 --------------
  // Pivot 2026-05-06: aToken transfers MUST revert. BIL is non-transferable.
  // PASS condition is now: the transfer reverts with ExceedsFreeBalance.
  await phase("7. aToken ERC20 transfer reverts (non-transferable by design)", async () => {
    const bal = await balanceOf(provider, A_STHDX, testerEvm);
    if (bal === 0n) throw new Error(`SKIP: no aToken to attempt transfer`);

    const alice = keyring.addFromUri("//Alice");
    const aliceEvm = "0x" + u8aToHex(alice.publicKey).slice(2, 42);

    const iface = new ethers.utils.Interface(["function transfer(address,uint256) returns (bool)"]);
    const amt = bal / 100n;
    const data = iface.encodeFunctionData("transfer", [aliceEvm, amt]);

    // Simulate via eth_call to get the revert reason cleanly without spending tx fee.
    try {
      await provider.call({
        from: testerEvm,
        to: A_STHDX,
        data,
      });
      // If it returns instead of reverting, that's a regression.
      throw new Error(`aToken.transfer DID NOT revert — non-transferability not enforced`);
    } catch (e: any) {
      const rd = e.error?.body || e.body || e.data || e.message;
      const txt = typeof rd === "string" ? rd : JSON.stringify(rd);
      // ExceedsFreeBalance(uint256,uint256) selector = 0x9e176ac9
      if (!txt.includes("0x9e176ac9") && !txt.includes("ExceedsFreeBalance"))
        throw new Error(`transfer reverted but not with ExceedsFreeBalance: ${txt.slice(0, 200)}`);
      return `revert ExceedsFreeBalance — non-transferability enforced ✓`;
    }
  });

  // -------------- Summary --------------
  section("SUMMARY");
  console.log("");
  console.log("  Phase                                                   Status   ");
  console.log("  " + "-".repeat(65));
  for (const r of results) {
    const icon = r.status === "pass" ? "PASS" : r.status === "skip" ? "SKIP" : "FAIL";
    console.log(`  ${r.phase.padEnd(54)} ${icon}`);
    if (r.status !== "pass") console.log(`    → ${r.note}`);
  }

  const failed = results.filter((r) => r.status === "fail");
  console.log("");
  if (failed.length === 0) {
    console.log("  ALL PHASES PASSED — BIL is fully operational end-to-end.");
  } else {
    console.log(`  ${failed.length} phase(s) failed. Blockers:`);
    for (const f of failed) console.log(`    - ${f.phase}: ${f.note}`);
  }
  console.log("");

  await api.disconnect();
  process.exit(failed.length === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(`\nFAILED: ${e.message}`);
  process.exit(1);
});
