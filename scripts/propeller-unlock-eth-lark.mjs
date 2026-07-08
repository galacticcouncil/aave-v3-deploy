#!/usr/bin/env node
// lift the ETH (asset 34) deposit lockdown + release Alice's reserved ETH on
// real lark2, via ONE Root referendum. lark2's circuit-breaker reserves all
// minted/deposited ETH (assetLockdownState=Locked); TC/gov force-lifts it.
//
//   circuitBreaker.forceLiftLockdown(34)        -> new deposits land free
//   circuitBreaker.releaseDeposit(ALICE, 34)    -> free the already-reserved ETH
//
// usage: node scripts/propeller-unlock-eth-lark.mjs [--live]

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const ALICE_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const ETH_ASSET = 34;
const HDX = 10n ** 12n;

async function signAndWait(tx, signer, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(signer.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(signer, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() };
        unsub?.(); return reject(new Error(`${e.section}.${e.name}`));
      }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const batch = api.tx.utility.batchAll([
    api.tx.circuitBreaker.forceLiftLockdown(ETH_ASSET),
    api.tx.circuitBreaker.releaseDeposit(ALICE_SS58, ETH_ASSET),
  ]);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  console.log(`ws=${WS} live=${LIVE} batch=${hash} len=${len}`);

  const before = await api.query.tokens.accounts(ALICE_SS58, ETH_ASSET);
  console.log(`Alice ETH before: free=${before.free.toBigInt()} reserved=${before.reserved.toBigInt()}`);
  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  try { await signAndWait(api.tx.preimage.notePreimage(hex), alice, api, "notePreimage"); }
  catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; console.log("  already noted"); }
  const ev = await signAndWait(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
  let ref = null;
  for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log(`  referendum #${ref}`);
  await signAndWait(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "deposit");
  await signAndWait(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) { console.log(`  [${i}] Approved`); break; }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error(`ref ${info.type}`);
  }
  await new Promise((r) => setTimeout(r, 18000));
  const after = await api.query.tokens.accounts(ALICE_SS58, ETH_ASSET);
  console.log(`\nAlice ETH after: free=${after.free.toBigInt()} (${after.free.toBigInt() / 10n ** 18n} ETH) reserved=${after.reserved.toBigInt()}`);
  const ld = await api.query.circuitBreaker.assetLockdownState(ETH_ASSET);
  console.log(`assetLockdownState(34): ${JSON.stringify(ld.toJSON())}`);
  console.log(after.free.toBigInt() > 0n ? "UNLOCKED ✓" : "still locked");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
