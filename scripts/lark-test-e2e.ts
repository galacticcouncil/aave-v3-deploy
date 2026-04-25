// End-to-end test for GIGAHDX on lark 1.
//
// Exercises the full user journey and reports which phases pass, which fail,
// and why. Designed to be re-run as upstream blockers (oracle, pallet bugs)
// are resolved — phases auto-skip dependencies on failure.
//
// Phases:
//   1. Preflight:   spec ≥ 406, required pallets, gigaHdxPoolContract, balance
//   2. Oracle:      getAssetPrice(stHDX), getAssetPrice(HOLLAR)
//   3. Supply:      gigaHdx.gigaStake → aGIGAHDXstHDX mint
//   4. Borrow:      Pool.borrow(HOLLAR) via evm.call
//   5. Repay:       HOLLAR.approve + Pool.repay via evm.call
//   6. Withdraw:    Pool.withdraw(stHDX) via evm.call
//   7. Transfer:    aGIGAHDXstHDX.transfer (LockableAToken free path)
//
// Usage:
//   WS_URL=wss://2.lark.hydration.cloud npx ts-node scripts/lark-test-e2e.ts
//   TESTER_URI=//Bob STAKE_HDX=200 npx ts-node scripts/lark-test-e2e.ts

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";
import { ethers } from "ethers";

const WS_URL = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const RPC_URL = process.env.RPC_URL || "https://2.lark.hydration.cloud";
const TESTER_URI = process.env.TESTER_URI || "//Bob";
const STAKE_HDX = BigInt(process.env.STAKE_HDX || "200") * BigInt(10 ** 12);

// Deployment addresses (lark 2, Apr 25 2026). See GIGAHDX-LARK2-ADDRESSES.md
const POOL = "0xb952AE92cC4D8D703d2d71Ab541baB34c94b944A";
const ORACLE = "0x1f14A240f5Aa8eDD4C5f375B82b3B1d836eF4983";
const STHDX = "0x000000000000000000000000000000010000029e";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const A_STHDX = "0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661"; // LockableAToken (stHDX aToken)
const VD_HOLLAR = "0x8Ba27f3761341D622574a70abD1EAe75845b5045"; // HOLLAR variable debt

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

  let supplyAToken = 0n;
  let hollarDebt = 0n;
  let oracleStHdxWorks = false;

  // -------------- Phase 1 --------------
  await phase("1. Preflight", async () => {
    const ver = await api.rpc.state.getRuntimeVersion();
    if (ver.specVersion.toNumber() < 406) throw new Error(`specVersion=${ver.specVersion.toNumber()} < 406`);

    const metadata = await api.rpc.state.getMetadata();
    const pallets = metadata.asLatest.pallets.map((p: any) => p.name.toString());
    for (const p of ["GigaHdx", "GigaHdxVoting", "FeeProcessor"]) {
      if (!pallets.includes(p)) throw new Error(`missing pallet: ${p}`);
    }

    const gp: any = await api.query.liquidation.gigaHdxPoolContract();
    if (gp.toString().toLowerCase() !== POOL.toLowerCase()) {
      throw new Error(`gigaHdxPoolContract=${gp} expected=${POOL}`);
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
  const suppliedOk = await phase("3. Supply (via gigaHdx.gigaStake)", async () => {
    const before = await balanceOf(provider, A_STHDX, testerEvm);
    await signAndWait(api.tx.gigaHdx.gigaStake(STAKE_HDX.toString()), tester, api, `gigaStake(${STAKE_HDX})`);
    await new Promise((r) => setTimeout(r, 6000));
    const after = await balanceOf(provider, A_STHDX, testerEvm);
    supplyAToken = after - before;
    if (supplyAToken === 0n) throw new Error(`aToken balance did not change`);
    return `aGIGAHDXstHDX Δ = +${supplyAToken} (~${Number(supplyAToken) / 1e12} stHDX)`;
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
  await phase("6. Withdraw stHDX", async () => {
    if (!suppliedOk) throw new Error(`SKIP: no supply`);
    const debtNow = await balanceOf(provider, VD_HOLLAR, testerEvm);
    if (debtNow > 0n && !oracleStHdxWorks) {
      throw new Error(`SKIP: outstanding debt + oracle blocked — HF check would revert`);
    }

    const iface = new ethers.utils.Interface(["function withdraw(address,uint256,address) returns (uint256)"]);
    const amt = supplyAToken / 10n; // withdraw 10% to keep margin
    const data = iface.encodeFunctionData("withdraw", [STHDX, amt, testerEvm]);

    const aBefore = await balanceOf(provider, A_STHDX, testerEvm);
    await callEvm(api, tester, testerEvm, POOL, data, `Pool.withdraw(${amt} stHDX, ~${Number(amt) / 1e12})`);
    await new Promise((r) => setTimeout(r, 6000));
    const aAfter = await balanceOf(provider, A_STHDX, testerEvm);
    const delta = aBefore - aAfter;
    if (delta === 0n) throw new Error(`aToken balance unchanged — withdraw silently failed`);
    return `aToken Δ = -${delta}`;
  });

  // -------------- Phase 7 --------------
  await phase("7. aToken ERC20 transfer (LockableAToken free path)", async () => {
    const bal = await balanceOf(provider, A_STHDX, testerEvm);
    if (bal === 0n) throw new Error(`SKIP: no aToken to transfer`);

    const alice = keyring.addFromUri("//Alice");
    const aliceEvm = "0x" + u8aToHex(alice.publicKey).slice(2, 42);

    const iface = new ethers.utils.Interface(["function transfer(address,uint256) returns (bool)"]);
    const amt = bal / 100n; // 1% of balance
    const data = iface.encodeFunctionData("transfer", [aliceEvm, amt]);

    const aBefore = await balanceOf(provider, A_STHDX, aliceEvm);
    await callEvm(api, tester, testerEvm, A_STHDX, data, `aGIGAHDXstHDX.transfer(Alice, ${amt})`);
    await new Promise((r) => setTimeout(r, 6000));
    const aAfter = await balanceOf(provider, A_STHDX, aliceEvm);
    const delta = aAfter - aBefore;
    if (delta === 0n) throw new Error(`Alice balance unchanged — transfer reverted silently or was blocked by lock check`);
    return `Alice aToken Δ = +${delta}`;
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
    console.log("  ALL PHASES PASSED — GIGAHDX is fully operational end-to-end.");
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
