#!/usr/bin/env node
// raise the SubLoop deploy/unwind router-swap slippage tolerance via gov
// configureDca (no redeploy). The deploy minOut assumed HOLLAR≈PRIME 1:1, but
// pool-143's actual HOLLAR→PRIME rate is ~96% → TradingLimitReached at 1%.
// configureDca(222,43,1043,143,period,slippagePpm) — raise ppm to 80000 (8%).
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";
const WS = "wss://2.lark.hydration.cloud";
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0", SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const HDX = 10n ** 12n;
const sl = new ethers.utils.Interface(["function configureDca(uint32,uint32,uint32,uint32,uint32,uint32)"]);
async function sign(tx, alice, api) { const nonce = await api.rpc.system.accountNextIndex(alice.address); return new Promise((res, rej) => { let u; tx.signAndSend(alice, { nonce }, ({ status, dispatchError }) => { if (!(status.isInBlock || status.isFinalized)) return; if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: "" + dispatchError }; u?.(); return rej(new Error(`${e.section}.${e.name}`)); } u?.(); res(); }).then((x) => { u = x; }).catch(rej); }); }
async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const inner = api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, SUBLOOP, sl.encodeFunctionData("configureDca", [222, 43, 1043, 143, 10, 80000]), "0", "600000", "100000000", null, null, [], []));
  const batch = api.tx.utility.batchAll([inner]);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  try { await sign(api.tx.preimage.notePreimage(hex), alice, api); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
  const ev = await sign2(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api);
  async function sign2(tx, a, ap) { const nonce = await ap.rpc.system.accountNextIndex(a.address); return new Promise((res, rej) => { let u; tx.signAndSend(a, { nonce }, ({ status, dispatchError, events }) => { if (!(status.isInBlock || status.isFinalized)) return; if (dispatchError) { u?.(); return rej(new Error("disp")); } u?.(); res(events); }).then((x) => { u = x; }).catch(rej); }); }
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log("ref #" + ref);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api);
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api);
  for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) break; if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
  await new Promise((r) => setTimeout(r, 18000));
  const ec = async (d) => (await api.call.ethereumRuntimeRPCApi.call("0xd43593c715fdd31c61141abd04a99fd6822c8558", SUBLOOP, d, "0", "2000000", null, null, null, false, null, null)).toJSON()?.ok?.value;
  console.log("dcaSlippagePpm now:", BigInt(await ec(new ethers.utils.Interface(["function dcaSlippagePpm() view returns (uint32)"]).encodeFunctionData("dcaSlippagePpm", []))).toString());
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
