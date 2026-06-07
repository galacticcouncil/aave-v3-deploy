#!/usr/bin/env node
// UUPS-upgrade the SubLoop proxy to the full-router impl (no DCA) via Root.
// preserves all state (loop position, shares, unwind accounting). GOV holds
// UPGRADER_ROLE; _authorizeUpgrade is onlyRole(UPGRADER_ROLE).
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const NEW_IMPL = process.argv.find((a) => a.startsWith("0x")) || "0x74ef3Dc474e430221046eD27745C8fCB3aB62e08";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const VAULT = "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const HDX = 10n ** 12n;
// this OZ version force-delegatecalls in upgradeToAndCall even with empty data
// (fails); upgradeTo(address) just swaps the impl slot — what we want.
const upg = new ethers.utils.Interface(["function upgradeTo(address)"]);
const vI = new ethers.utils.Interface(["function requestRedeem(uint256,address) returns (uint256)"]);

async function sign(tx, alice, api) {
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
  const ethCall = async (to, data) => (await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "8000000", null, null, null, false, null, null)).toJSON();
  const implOf = async () => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, SUBLOOP, "0x5c60da1b", "0", "200000", null, null, null, false, null, null); return r.toJSON()?.ok?.value; };
  // read impl via storage slot (proxiableUUID/ERC1967)
  const slot = await api.rpc.eth.getStorageAt(SUBLOOP, IMPL_SLOT).catch(() => null);
  console.log("impl before:", slot ? "0x" + slot.toHex().slice(-40) : "?", "→ target", NEW_IMPL);
  console.log("requestRedeem SIM before:", JSON.stringify((await ethCall(VAULT, vI.encodeFunctionData("requestRedeem", [(10n * 10n ** 18n).toString(), ALICE_EVM])))?.ok?.exitReason ?? {}));
  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  const inner = api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, SUBLOOP, upg.encodeFunctionData("upgradeTo", [NEW_IMPL]), "0", "2000000", "100000000", null, null, [], []));
  const batch = api.tx.utility.batchAll([inner]);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  try { await sign(api.tx.preimage.notePreimage(hex), alice, api); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
  const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api);
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log("ref #" + ref);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api);
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api);
  for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) break; if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
  await new Promise((r) => setTimeout(r, 18000));
  const slot2 = await api.rpc.eth.getStorageAt(SUBLOOP, IMPL_SLOT).catch(() => null);
  console.log("impl after:", slot2 ? "0x" + slot2.toHex().slice(-40) : "?");
  const sim = await ethCall(VAULT, vI.encodeFunctionData("requestRedeem", [(10n * 10n ** 18n).toString(), ALICE_EVM]));
  const ok = JSON.stringify(sim?.ok?.exitReason ?? {}).match(/ucceed/);
  console.log("requestRedeem SIM after:", JSON.stringify(sim?.ok?.exitReason ?? sim), ok ? "→ WORKS ✓" : "→ still failing");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
