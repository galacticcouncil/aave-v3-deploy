#!/usr/bin/env node
// fix the unwind DCA tranche scale on lark2 via one Root referendum.
// setTranches(deploy, unwind): deploy = HOLLAR (18dp), unwind = aPRIME (6dp).
// the wiring set both to 5000e18 — correct for deploy, but 1e12x too large for
// the 6dp aPRIME unwind → unwind DCA schedule DispatchFailed (0xf4c0eb20).
// fix: setTranches(5000e18, 10000e6). then re-simulate requestRedeem.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const VAULT = "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const HDX = 10n ** 12n;
const slI = new ethers.utils.Interface(["function setTranches(uint256,uint256)", "function deployTranche() view returns (uint256)", "function unwindTranche() view returns (uint256)"]);
const vI = new ethers.utils.Interface(["function requestRedeem(uint256,address) returns (uint256)"]);
const DEPLOY_TRANCHE = (5000n * 10n ** 18n).toString();
const UNWIND_TRANCHE = (10000n * 10n ** 6n).toString();

async function sign(tx, alice, api, label) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => { let u; tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
    if (!(status.isInBlock || status.isFinalized)) return;
    if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: "" + dispatchError }; u?.(); return rej(new Error(`${e.section}.${e.name}`)); }
    u?.(); res(events); }).then((x) => { u = x; }).catch(rej); });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const ethCall = async (to, data) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "8000000", null, null, null, false, null, null); return r.toJSON(); };
  const tr = async () => [BigInt((await ethCall(SUBLOOP, slI.encodeFunctionData("deployTranche", []))).ok.value), BigInt((await ethCall(SUBLOOP, slI.encodeFunctionData("unwindTranche", []))).ok.value)];
  let [d, u] = await tr();
  console.log(`tranches before: deploy=${d} unwind=${u}`);
  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  const aaveMgr = api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, SUBLOOP, slI.encodeFunctionData("setTranches", [DEPLOY_TRANCHE, UNWIND_TRANCHE]), "0", "600000", "100000000", null, null, [], []));
  const batch = api.tx.utility.batchAll([aaveMgr]);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  try { await sign(api.tx.preimage.notePreimage(hex), alice, api); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
  const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api);
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log(`ref #${ref}`);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api);
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api);
  for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) break; if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
  await new Promise((r) => setTimeout(r, 18000));
  [d, u] = await tr();
  console.log(`tranches after: deploy=${d} unwind=${u}`);

  // re-simulate requestRedeem
  const sim = await ethCall(VAULT, vI.encodeFunctionData("requestRedeem", [(10n * 10n ** 18n).toString(), ALICE_EVM]));
  const val = sim?.ok?.value ?? "0x";
  console.log("requestRedeem SIM:", JSON.stringify(sim?.ok?.exitReason ?? sim), "val:", typeof val === "string" ? val.slice(0, 20) : val);
  console.log(JSON.stringify(sim?.ok?.exitReason ?? {}).includes("ucceed") ? "SIM OK ✓ — requestRedeem will work now" : "still reverting");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
