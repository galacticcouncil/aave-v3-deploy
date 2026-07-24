// One-shot: build + submit a Root proposal that registers two router routes
// for the new BIL stablepool, signed as //Alice on lark.
//
//   H2O (1)   → BIL (550): [Omnipool 1→222, Stableswap 10055: 222→550]
//   WETH (20) → BIL (550): [Stableswap 104: 20→1007, Stableswap 4200: 1007→4200,
//                            Aave 4200→420, Omnipool 420→222, Stableswap 10055: 222→550]

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";

const RPC = process.env.RPC || "wss://0.lark.hydration.cloud";
const POOL_ID = 10055;
const HOLLAR = 222;
const BIL = 550;
const H2O = 1;
const WETH = 20;

await cryptoWaitReady();
const api = await ApiPromise.create({ provider: new WsProvider(RPC), noInitWarn: true });
const chain = (await api.rpc.system.chain()).toString();
console.log(`Chain: ${chain}`);

const keyring = new Keyring({ type: "sr25519" });
const alice = keyring.addFromUri("//Alice");
console.log(`Alice: ${alice.address}`);

// ---- Pre-flight: pool exists, no existing routes for the two pairs ----
const pool = await api.query.stableswap.pools(POOL_ID);
if (!pool.isSome) throw new Error(`Pool ${POOL_ID} not found — did the stablepool launch run?`);

for (const [ai, ao, label] of [[H2O, BIL, "H2O→BIL"], [WETH, BIL, "WETH→BIL"]]) {
  const existing = await api.query.router.routes({ assetIn: ai, assetOut: ao });
  if (existing && existing.length > 0) {
    console.log(`  WARN: route for ${label} already exists, will be overwritten`);
  }
}

// ---- Build the 2 route inserts ----
const route_H2O_BIL = api.tx.router.forceInsertRoute(
  { assetIn: H2O, assetOut: BIL },
  [
    { pool: "Omnipool", assetIn: H2O, assetOut: HOLLAR },
    { pool: { Stableswap: POOL_ID }, assetIn: HOLLAR, assetOut: BIL },
  ],
);

const route_WETH_BIL = api.tx.router.forceInsertRoute(
  { assetIn: WETH, assetOut: BIL },
  [
    { pool: { Stableswap: 104 }, assetIn: WETH, assetOut: 1007 },
    { pool: { Stableswap: 4200 }, assetIn: 1007, assetOut: 4200 },
    { pool: "Aave", assetIn: 4200, assetOut: 420 },
    { pool: "Omnipool", assetIn: 420, assetOut: HOLLAR },
    { pool: { Stableswap: POOL_ID }, assetIn: HOLLAR, assetOut: BIL },
  ],
);

const batchAll = api.tx.utility.batchAll([route_H2O_BIL, route_WETH_BIL]);
const proposalHex = batchAll.method.toHex();
const proposalHash = batchAll.method.hash.toHex();
const proposalLen = batchAll.method.encodedLength;
console.log(`\nbatchAll hex (${proposalLen} bytes), hash = ${proposalHash}`);

// ---- Helper: sign + wait ----
const signAndWait = (tx, label) => new Promise((resolve, reject) => {
  console.log(`\n--- ${label} ---`);
  let unsub;
  tx.signAndSend(alice, async ({ status, dispatchError, events }) => {
    if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
    if (status.isInBlock || status.isFinalized) {
      if (dispatchError) {
        const msg = dispatchError.isModule
          ? (() => { const d = api.registry.findMetaError(dispatchError.asModule); return `${d.section}.${d.name}: ${d.docs.join(" ")}`; })()
          : dispatchError.toString();
        if (unsub) unsub();
        reject(new Error(msg));
        return;
      }
      for (const { event } of events) console.log(`  event: ${event.section}.${event.method}`);
      if (unsub) unsub();
      resolve(events);
    }
  }).then((u) => { unsub = u; }).catch(reject);
});

// ---- Note preimage ----
try {
  await signAndWait(api.tx.preimage.notePreimage(proposalHex), "preimage.notePreimage");
} catch (e) {
  if (!/AlreadyNoted/i.test(e.message)) throw e;
  console.log("  (already noted, continuing)");
}

// ---- Submit Root referendum ----
const submitEvents = await signAndWait(
  api.tx.referenda.submit(
    { system: "Root" },
    { Lookup: { hash: proposalHash, len: proposalLen } },
    { After: 1 },
  ),
  "referenda.submit(Root)",
);
let refIndex = null;
for (const { event } of submitEvents) {
  if (event.section === "referenda" && event.method === "Submitted") {
    refIndex = event.data[0].toNumber();
    break;
  }
}
if (refIndex == null) throw new Error("no refIndex");
console.log(`Referendum: ${refIndex}`);

// ---- Decision deposit + vote ----
await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), "placeDecisionDeposit");
const voteBalance = (BigInt(4_000_000_000) * BigInt(10 ** 12)).toString();
await signAndWait(
  api.tx.convictionVoting.vote(refIndex, {
    Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
  }),
  "convictionVoting.vote",
);

// ---- Poll for approval + enactment ----
console.log("\nPolling for approval + enactment...");
for (let i = 0; i < 60; i++) {
  await new Promise((r) => setTimeout(r, 3000));
  const ref = await api.query.referenda.referendumInfoFor(refIndex);
  if (!ref.isSome) continue;
  const info = ref.unwrap();
  console.log(`  [${i}] ${info.type}`);
  if (info.isApproved) break;
  if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
    throw new Error(`Ref ${refIndex} ${info.type}`);
  }
}
console.log("Waiting 18s for enactment...");
await new Promise((r) => setTimeout(r, 18000));

// ---- Verify routes are now registered ----
console.log("\n=== Post-state verification ===");
for (const [ai, ao, label] of [[H2O, BIL, "H2O→BIL"], [WETH, BIL, "WETH→BIL"]]) {
  const r = await api.query.router.routes({ assetIn: ai, assetOut: ao });
  const ok = r && r.length > 0;
  console.log(`  ${label}: ${ok ? "✓ " + JSON.stringify(r.toHuman()).slice(0, 200) : "✗ MISSING"}`);
}

await api.disconnect();
