#!/usr/bin/env node
// Alice hit convictionVoting.MaxVotesReached (≈20 referenda this session + her
// fork-state votes). Remove her votes on already-decided referenda to free slots,
// then vote aye on the pending referendum (arg) and wait for enactment.
//   node scripts/propeller-clean-votes-finish.mjs <refIndex> [proxy] [expectedImpl]
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
const WS = "wss://2.lark.hydration.cloud";
const REF = Number(process.argv[2]);
const PROXY = process.argv[3];
const EXPECT = (process.argv[4] || "").toLowerCase();
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const HDX = 10n ** 12n;
async function sign(tx, alice, api, label) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => { let u; tx.signAndSend(alice, { nonce }, ({ status, dispatchError }) => { if (!(status.isInBlock || status.isFinalized)) return; if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: "" + dispatchError }; u?.(); return rej(new Error(`${label}: ${e.section}.${e.name}`)); } u?.(); res(); }).then((x) => { u = x; }).catch(rej); });
}
async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  // gather Alice's votes per class; removeVote for any referendum not ongoing
  const entries = await api.query.convictionVoting.votingFor.entries(alice.address);
  const removals = [];
  for (const [k, v] of entries) {
    const cls = k.args[1].toNumber();
    const j = v.toJSON();
    const votes = j?.casting?.votes || [];
    for (const [refIdx] of votes) {
      const info = await api.query.referenda.referendumInfoFor(refIdx);
      const ongoing = info.isSome && info.unwrap().isOngoing;
      if (!ongoing && refIdx !== REF) removals.push([cls, refIdx]);
    }
  }
  console.log(`removing ${removals.length} stale votes`);
  // batch removals to save time
  const calls = removals.map(([c, r]) => api.tx.convictionVoting.removeVote(c, r));
  for (let i = 0; i < calls.length; i += 50) {
    await sign(api.tx.utility.batch(calls.slice(i, i + 50)), alice, api, "removeVote batch");
  }
  // now vote aye on the pending referendum
  await sign(api.tx.convictionVoting.vote(REF, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
  console.log(`voted aye on #${REF}`);
  for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(REF)).unwrap(); if (info.isApproved) { console.log("approved"); break; } if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
  await new Promise((r) => setTimeout(r, 18000));
  if (PROXY) {
    const slot = await api.rpc.eth.getStorageAt(PROXY, IMPL_SLOT).catch(() => null);
    const impl = slot ? "0x" + slot.toHex().slice(-40) : "?";
    console.log("impl after:", impl, EXPECT ? (impl === EXPECT ? "→ MATCHES ✓" : "→ mismatch") : "");
  }
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
