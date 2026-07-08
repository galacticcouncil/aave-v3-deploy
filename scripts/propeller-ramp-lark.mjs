#!/usr/bin/env node
// ramp the Propeller loop on real lark2: grant KEEPER to //Alice's EVM (one Root
// referendum if needed), then call SubLoop.pokeBorrow() repeatedly. each poke
// borrows more HOLLAR against the growing aPRIME and refills the DCA, levering
// the loop toward target HF 1.05 and pushing more HOLLAR into pool-143.
//
// usage: node scripts/propeller-ramp-lark.mjs [--live] [iterations]

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady, blake2AsU8a } from "@polkadot/util-crypto";
import { u8aToHex } from "@polkadot/util";
import { ethers } from "ethers";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const ITERS = Number(process.argv.find((a) => /^\d+$/.test(a)) || 6);
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const APRIME = "0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const HDX = 10n ** 12n;

const sl = new ethers.utils.Interface([
  "function pokeBorrow()", "function grantRole(bytes32,address)", "function hasRole(bytes32,address) view returns (bool)",
  "function healthFactor() view returns (uint256)", "function totalEquity() view returns (uint256)",
]);
const erc = new ethers.utils.Interface(["function balanceOf(address) view returns (uint256)"]);
const KEEPER = ethers.utils.id("KEEPER_ROLE");

function poolH160(id) {
  const name = new Uint8Array([...new TextEncoder().encode("sts"), ...new Uint8Array(new Uint32Array([id]).buffer)]);
  return u8aToHex(blake2AsU8a(name, 256)).slice(0, 42);
}

async function sign(tx, alice, api, label) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() }; unsub?.(); return reject(new Error(`${e.section}.${e.name}`)); }
      let failed = "";
      for (const { event } of events) if (event.section === "evm" && event.method === "ExecutedFailed") failed = JSON.stringify(event.data.toJSON()).slice(0, 120);
      unsub?.(); resolve({ events, failed });
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const evmCall = (to, data, gas) => api.tx.evm.call(ALICE_EVM, to, data, "0", gas, "600000000", null, null, [], []);
  const ethCall = async (to, data) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "12000000", null, null, null, false, null, null); return r.toJSON()?.ok?.value ?? "0x"; };
  const aprime = async () => { const r = await ethCall(APRIME, erc.encodeFunctionData("balanceOf", [SUBLOOP])); return r !== "0x" ? Number(BigInt(r)) / 1e6 : 0; };
  const hf = async () => { const r = await ethCall(SUBLOOP, sl.encodeFunctionData("healthFactor", [])); return r !== "0x" ? Number(BigInt(r)) / 1e18 : -1; };
  const pa = poolH160(143);
  const poolHollar = async () => { const r = await ethCall(HOLLAR, erc.encodeFunctionData("balanceOf", [pa])); return r !== "0x" ? Number(BigInt(r)) / 1e18 : 0; };
  const poolPrime = async () => (await api.query.tokens.accounts(u8aToHex(blake2AsU8a(new Uint8Array([...new TextEncoder().encode("sts"), ...new Uint8Array(new Uint32Array([143]).buffer)]), 256)), 43)).free.toBigInt();

  const hasKeeper = async () => { const r = await ethCall(SUBLOOP, sl.encodeFunctionData("hasRole", [KEEPER, ALICE_EVM])); return r !== "0x" && BigInt(r) === 1n; };
  console.log(`start: aPRIME=${(await aprime()).toFixed(0)} HF=${(await hf()).toExponential(2)} poolPRIME=${(await poolPrime()) / 10n ** 6n} poolHOLLAR=${(await poolHollar()).toFixed(0)} keeper=${await hasKeeper()}`);
  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  if (!(await hasKeeper())) {
    console.log("\ngranting KEEPER to ALICE_EVM via Root referendum...");
    const aaveMgr = api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, SUBLOOP, sl.encodeFunctionData("grantRole", [KEEPER, ALICE_EVM]), "0", "600000", "100000000", null, null, [], []));
    const batch = api.tx.utility.batchAll([aaveMgr]);
    const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
    try { await sign(api.tx.preimage.notePreimage(hex), alice, api, "note"); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
    const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
    let ref = null; for (const { event } of ev.events) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
    console.log(`  ref #${ref}`);
    await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "dep");
    await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
    for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) break; if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
    await new Promise((r) => setTimeout(r, 18000));
    console.log(`  KEEPER granted: ${await hasKeeper()}`);
  }

  for (let i = 0; i < ITERS; i++) {
    // wait ~12 blocks for the DCA to deploy another tranche of aPRIME
    const start = (await api.rpc.chain.getHeader()).number.toNumber();
    while ((await api.rpc.chain.getHeader()).number.toNumber() < start + 12) await new Promise((r) => setTimeout(r, 3000));
    const r = await sign(evmCall(SUBLOOP, sl.encodeFunctionData("pokeBorrow", []), "12000000"), alice, api, `poke${i}`);
    console.log(`poke${i}: aPRIME=${(await aprime()).toFixed(0)} HF=${(await hf()).toFixed(4)} poolPRIME=${(await poolPrime()) / 10n ** 6n} poolHOLLAR=${(await poolHollar()).toFixed(0)}${r.failed ? " FAIL " + r.failed : ""}`);
  }
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
