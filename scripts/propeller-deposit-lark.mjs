#!/usr/bin/env node
// drive the Propeller vault deposit on real lark2 as //Alice (her EVM address
// 0xd435.. is the truncation of her substrate key, so she signs evm.call
// directly via substrate; gas is paid from that EVM account, which has ETH).
//
//   1. approve(vault, amt) on the ETH ERC20 (0x..0022)
//   2. simulate deposit via ethereumRuntimeRPCApi (surface any revert)
//   3. deposit(amt, alice) → supplies ETH, borrows HOLLAR, mints+supplies synth,
//      seeds SubLoop → SubLoop schedules the HOLLAR→PRIME DCA on pool-143
//   4. verify shares / Main HF / pool-143 HOLLAR
//
// usage: node scripts/propeller-deposit-lark.mjs [--live]

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady, blake2AsU8a } from "@polkadot/util-crypto";
import { u8aToHex } from "@polkadot/util";
import { ethers } from "ethers";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const ETH20 = "0x0000000000000000000000000000000100000022";
const VAULT = process.env.VAULT || "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const AMT = process.env.AMT ? BigInt(Math.round(parseFloat(process.env.AMT) * 1e6)) * 10n ** 12n : 35n * 10n ** 18n;

const erc = new ethers.utils.Interface(["function approve(address,uint256)", "function balanceOf(address) view returns (uint256)"]);
const vI = new ethers.utils.Interface([
  "function deposit(uint256,address) returns (uint256)", "function balanceOf(address) view returns (uint256)",
  "function totalAssets() view returns (uint256)", "function loopShares() view returns (uint256)", "function syntheticSupplied() view returns (uint256)",
]);
const accI = new ethers.utils.Interface(["function getUserAccountData(address) view returns (uint256 tc,uint256 td,uint256 ab,uint256 lt,uint256 ltv,uint256 hf)"]);

function poolAcct(id) {
  const name = new Uint8Array([...new TextEncoder().encode("sts"), ...new Uint8Array(new Uint32Array([id]).buffer)]);
  return u8aToHex(blake2AsU8a(name, 256));
}

async function sign(tx, alice, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() }; unsub?.(); return reject(new Error(`${e.section}.${e.name}`)); }
      for (const { event } of events) {
        const k = `${event.section}.${event.method}`;
        if (k === "evm.ExecutedFailed" || k === "evm.Executed") console.log(`  ${k}`, JSON.stringify(event.data.toJSON()).slice(0, 160));
      }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const evmCall = (to, data, gas) => api.tx.evm.call(ALICE_EVM, to, data, "0", gas, "600000000", null, null, [], []);
  const ethCall = async (to, data) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "30000000", null, null, null, false, null, null); return r.toJSON(); };

  const bal = await ethCall(ETH20, erc.encodeFunctionData("balanceOf", [ALICE_EVM]));
  console.log(`Alice EVM ETH: ${Number(BigInt(bal?.ok?.value ?? "0")) / 1e18} | depositing ${AMT / 10n ** 18n} ETH`);
  const pa = poolAcct(143);
  const ph0 = (await api.query.tokens.accounts(pa, 222)).free.toBigInt();
  const pp0 = (await api.query.tokens.accounts(pa, 43)).free.toBigInt();
  console.log(`pool-143 before: PRIME=${pp0 / 10n ** 6n} HOLLAR=${ph0 / 10n ** 18n}`);

  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  await sign(evmCall(ETH20, erc.encodeFunctionData("approve", [VAULT, AMT.toString()]), "300000"), alice, api, "approve");

  // simulate deposit to surface revert reason
  const sim = await ethCall(VAULT, vI.encodeFunctionData("deposit", [AMT.toString(), ALICE_EVM]));
  const val = sim?.ok?.value ?? "0x";
  let reason = "";
  if (typeof val === "string" && val.startsWith("0x08c379a0")) reason = ethers.utils.defaultAbiCoder.decode(["string"], "0x" + val.slice(10))[0];
  console.log("deposit SIM exitReason:", JSON.stringify(sim?.ok?.exitReason ?? sim), reason ? `reason="${reason}"` : "");

  await sign(evmCall(VAULT, vI.encodeFunctionData("deposit", [AMT.toString(), ALICE_EVM]), "15000000"), alice, api, "deposit");

  // verify
  const shares = await ethCall(VAULT, vI.encodeFunctionData("balanceOf", [ALICE_EVM]));
  const ud = accI.decodeFunctionResult("getUserAccountData", (await ethCall(POOL, accI.encodeFunctionData("getUserAccountData", [VAULT]))).ok.value);
  console.log(`vault shares: ${BigInt(shares?.ok?.value ?? "0").toString()}`);
  console.log(`vault Main: coll8=${ud.tc.toString()} debt8=${ud.td.toString()} HF=${ud.hf.toString()}`);
  const ph1 = (await api.query.tokens.accounts(pa, 222)).free.toBigInt();
  const pp1 = (await api.query.tokens.accounts(pa, 43)).free.toBigInt();
  console.log(`pool-143 after: PRIME=${pp1 / 10n ** 6n} HOLLAR=${ph1 / 10n ** 18n}`);
  console.log(`DCA schedules: ${(await api.query.dca.scheduleIdsPerBlock.entries()).length} blocks queued; total ${(await api.query.dca.schedules.keys()).length}`);
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
