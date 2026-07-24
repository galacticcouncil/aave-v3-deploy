// Submit the BIL launch preimage as a Root referendum on node0.lark via Alice.
// Mirrors scripts/submit-bil-routes-lark.mjs but for the full bil.ts preimage.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady, blake2AsHex } from "@polkadot/util-crypto";
import { readFileSync } from "fs";

const WS = process.env.WS || "wss://node0.lark.hydration.cloud";
const HEX_PATH = process.argv[2] || "/tmp/bil-mainnet.hex";

await cryptoWaitReady();
const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
const chain = (await api.rpc.system.chain()).toString();
const head = (await api.rpc.chain.getHeader()).number.toNumber();
console.log(`Chain: ${chain} @ #${head}`);

const keyring = new Keyring({ type: "sr25519" });
const alice = keyring.addFromUri("//Alice");
console.log(`Alice: ${alice.address}`);

const proposalHex = readFileSync(HEX_PATH, "utf-8").trim();
const proposalLen = (proposalHex.length - 2) / 2;
const proposalHash = blake2AsHex(proposalHex);
console.log(`Proposal: ${proposalLen} bytes, hash ${proposalHash}\n`);

const signAndWait = (tx, label) =>
  new Promise((resolve, reject) => {
    console.log(`--- ${label} ---`);
    let unsub;
    tx.signAndSend(alice, { nonce: -1 }, async ({ status, dispatchError, events }) => {
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
        for (const { event } of events) console.log(`  ${event.section}.${event.method}`);
        if (unsub) unsub();
        resolve(events);
      }
    }).then((u) => { unsub = u; }).catch(reject);
  });

// 1. Note the preimage.
try {
  await signAndWait(api.tx.preimage.notePreimage(proposalHex), "preimage.notePreimage");
} catch (e) {
  if (!/AlreadyNoted/i.test(e.message)) throw e;
  console.log("  (already noted, continuing)");
}

// 2. Submit Root referendum.
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
console.log(`\nReferendum: ${refIndex}\n`);

// 3. Decision deposit.
await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), "placeDecisionDeposit");

// 4. Vote (Locked6x, 4M HDX).
const voteBalance = (BigInt(4_000_000_000) * BigInt(10 ** 12)).toString();
await signAndWait(
  api.tx.convictionVoting.vote(refIndex, {
    Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
  }),
  "convictionVoting.vote",
);

// 5. Poll for approval.
console.log("\nPolling for approval...");
let lastStatus = null;
for (let i = 0; i < 90; i++) {
  await new Promise((r) => setTimeout(r, 3000));
  const ref = await api.query.referenda.referendumInfoFor(refIndex);
  if (!ref.isSome) continue;
  const info = ref.unwrap();
  const status = info.type;
  if (status !== lastStatus) {
    console.log(`  [${i * 3}s] ${status}`);
    lastStatus = status;
  }
  if (info.isApproved) break;
  if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
    throw new Error(`Ref ${refIndex} ${status}`);
  }
}

// 6. Wait for enactment.
console.log("\nWaiting 24s for enactment...");
await new Promise((r) => setTimeout(r, 24000));

// 7. Verify state.
console.log("\n=== Post-enactment verification ===");
for (const id of [55, 550, 10055]) {
  const a = await api.query.assetRegistry.assets(id);
  console.log(`  asset ${id}: ${a.toHuman()?.name ?? "—"} / ${a.toHuman()?.symbol ?? "—"}`);
}
const lp = await api.query.tokens.totalIssuance(10055);
console.log(`  2-Pool-BIL LP issuance: ${lp.toString()}`);
for (const [ai, ao, label] of [[0, 55, "HDX→BIL"], [20, 55, "WETH→BIL"]]) {
  const r = await api.query.router.routes({ assetIn: ai, assetOut: ao });
  console.log(`  ${label}: ${(r.toJSON() ?? []).length} hops`);
}

await api.disconnect();
console.log("\ndone.");
