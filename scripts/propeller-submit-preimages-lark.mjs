#!/usr/bin/env node
// Submit the preimages emitted by `npx hardhat propeller` as Root referenda on a
// real lark fork, voting each through with Alice and scanning the enactment block
// for the dispatch result.
//
// WHY THIS EXISTS
// ---------------
// `tasks/proposals/propeller.ts` is the single source of truth for WHAT gets
// wired; the older `propeller-wire-*-lark.mjs` scripts each rebuilt the batches
// themselves with per-lark hardcoded addresses, so they drifted. This one is
// dumb on purpose: it takes the hex the hardhat task printed and enacts it.
//
// The scan for `ExecutedFailed` is the whole point of the exercise —
// `dispatcher.dispatchAsAaveManager` reports EVM reverts as EVENTS, not as
// extrinsic failures, so a referendum can enact "successfully" with individual
// calls silently reverted. Always follow up with verify-readiness.ts.
//
// usage:
//   npx hardhat propeller --network hydration > /tmp/preimages.txt
//   node scripts/propeller-submit-preimages-lark.mjs /tmp/preimages.txt            # dry-run
//   node scripts/propeller-submit-preimages-lark.mjs /tmp/preimages.txt --live
//   … --live --only 0,1        # enact just batches 0 and 1
//
// env: PROPOSAL_WS (default wss://4.lark.hydration.cloud), SEED (default //Alice)

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import fs from "fs";

const WS = process.env.PROPOSAL_WS || "wss://4.lark.hydration.cloud";
const SEED = process.env.SEED || "//Alice";
const LIVE = process.argv.includes("--live");
const file = process.argv[2];
const onlyArg = process.argv.indexOf("--only");
const ONLY =
  onlyArg > -1 && process.argv[onlyArg + 1]
    ? new Set(process.argv[onlyArg + 1].split(",").map((s) => s.trim()))
    : null;
const HDX = 10n ** 12n;

/// Pull `===== BATCH n — label (…) =====` / `0x…` pairs out of the task output.
/// The hex search MUST stop at the next `=====` header: an empty batch prints
/// `===== BATCH 0 … EMPTY — nothing to do =====` with no hex of its own, and a
/// naive fixed-width lookahead then attributes the NEXT batch's hex to it — which
/// silently submits that batch twice.
function parseBatches(text) {
  const lines = text.split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^=====\s+(BATCH\s+(\d+)[^=]*?)\s+=====$/);
    if (!m) continue;
    if (/EMPTY/i.test(lines[i])) continue;
    let hex = null;
    for (let j = i + 1; j < lines.length && !/^=====/.test(lines[j]); j++) {
      if (/^0x[0-9a-fA-F]+$/.test(lines[j].trim())) { hex = lines[j].trim(); break; }
    }
    if (hex) out.push({ index: m[2], label: m[1].trim(), hex });
  }
  return out;
}

async function signAndWait(tx, signer, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(signer.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(signer, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule
          ? api.registry.findMetaError(dispatchError.asModule)
          : { section: "", name: dispatchError.toString() };
        unsub?.();
        return reject(new Error(`${e.section}.${e.name}`));
      }
      console.log("  OK");
      unsub?.();
      resolve(events);
    })
      .then((u) => { unsub = u; })
      .catch(reject);
  });
}

async function enact(api, alice, call, label) {
  const hex = call.toHex();
  const hash = call.hash.toHex();
  const len = call.encodedLength;
  console.log(`\n===== ${label}: hash=${hash} len=${len} =====`);

  try {
    await signAndWait(api.tx.preimage.notePreimage(hex), alice, api, `notePreimage(${label})`);
  } catch (e) {
    if (!/AlreadyNoted/i.test(e.message)) throw e;
    console.log("  already noted");
  }

  const ev = await signAndWait(
    api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }),
    alice, api, `submit(${label})`
  );
  let ref = null;
  for (const { event } of ev)
    if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  if (ref == null) throw new Error("no refIndex");
  console.log(`  referendum #${ref}`);

  await signAndWait(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "deposit");
  await signAndWait(
    api.tx.convictionVoting.vote(ref, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() },
    }),
    alice, api, "vote"
  );

  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) { console.log(`  [${i}] Approved`); break; }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled)
      throw new Error(`ref ${info.type}`);
  }

  // Enactment + the silent-revert scan.
  //
  // TWO traps here, both hit on lark-4:
  //  1. EVERY block carries a housekeeping `scheduler.Dispatched [[n,0], null, ok]`.
  //     Matching on section.method alone locks onto that and reports "ok" for a
  //     batch that actually failed. The referendum's own dispatch is the one with
  //     a NON-NULL task id (data[1]), so filter on that.
  //  2. Stopping the scan at the first Dispatched truncates the window before the
  //     EVM calls in the same block emit their events. Always scan to the end.
  let dispatched = false;
  const failures = [];
  for (let b = 0; b < 14; b++) {
    await new Promise((r) => setTimeout(r, 3000));
    const head = (await api.rpc.chain.getHeader()).number.toNumber();
    const apiAt = await api.at(await api.rpc.chain.getBlockHash(head));
    for (const { event } of await apiAt.query.system.events()) {
      const k = `${event.section}.${event.method}`;
      if (k === "scheduler.Dispatched") {
        const [, taskId, result] = event.data.toJSON();
        if (taskId == null) continue; // housekeeping, not our referendum
        const failed = JSON.stringify(result).match(/err/i);
        console.log(`  scheduler.Dispatched @${head}:`, failed ? `FAILED ${JSON.stringify(result)}` : "ok");
        if (failed) failures.push(`scheduler.Dispatched FAILED ${JSON.stringify(result)}`);
        dispatched = true;
      }
      if (/ExecutedFailed|BatchInterrupted|ExtrinsicFailed/.test(event.method)) {
        const d = JSON.stringify(event.data.toJSON()).slice(0, 240);
        failures.push(`${k}: ${d}`);
        console.log(`  ⚠ ${k}: ${d}`);
      }
    }
    if (dispatched && b > 1) break; // give the batch's own events a block to land
  }
  if (!dispatched) console.log("  (no scheduler.Dispatched seen in scan window)");
  return failures;
}

async function main() {
  if (!file) throw new Error("pass the hardhat propeller output file as argv[2]");
  const batches = parseBatches(fs.readFileSync(file, "utf8"));
  if (!batches.length) throw new Error(`no '===== BATCH n … =====' + 0x… pairs found in ${file}`);

  await cryptoWaitReady();
  const api = await ApiPromise.create({
    provider: new WsProvider(WS, 2500, {}, 600000), // long RPC timeout: initReserves is a heavy block
    noInitWarn: true,
  });
  const alice = new Keyring({ type: "sr25519" }).addFromUri(SEED);
  console.log(`endpoint ${WS}\nsigner   ${alice.address}\nbatches  ${batches.length}${LIVE ? "" : "   (DRY-RUN — pass --live to submit)"}`);

  const allFailures = [];
  for (const b of batches) {
    if (ONLY && !ONLY.has(b.index)) { console.log(`\n— skipping ${b.label} (not in --only)`); continue; }
    const call = api.createType("Call", b.hex);
    console.log(`\n${b.label}: ${call.section}.${call.method}, ${call.args?.[0]?.length ?? "?"} inner calls, ${call.encodedLength} bytes`);
    if (!LIVE) continue;
    allFailures.push(...(await enact(api, alice, call, b.label)).map((f) => `${b.label} → ${f}`));
  }

  if (LIVE) {
    console.log(
      allFailures.length
        ? `\n⚠ ${allFailures.length} silent failure event(s):\n  ${allFailures.join("\n  ")}`
        : "\nNo ExecutedFailed/BatchInterrupted events seen."
    );
    console.log("\nRun scripts/propeller/verify-readiness.ts before trusting any of this.");
  }
  await api.disconnect();
}

main().catch((e) => { console.error(e); process.exit(1); });
