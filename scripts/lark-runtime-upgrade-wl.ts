// Runtime upgrade on a lark testnet via whitelisted_caller track (50k HDX deposit vs 1M on Root).
// Default target: lark 2. Override via WS_URL env var.
//
// Flow:
//   1. TC (Alice) whitelists hash of inner call: system.authorizeUpgrade(codeHash)
//   2. Note preimage for wrapper: whitelist.dispatchWhitelistedCallWithPreimage(inner)
//   3. Submit referendum on track 1 (whitelisted_caller) referencing the wrapper preimage
//   4. Alice votes, referendum approves, wrapper dispatches with WhitelistedCaller origin
//      → inner authorizeUpgrade runs with Root origin → upgrade authorized
//   5. Call system.applyAuthorizedUpgrade(wasm) to execute

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import * as fs from "fs";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
// Max HDX per conviction vote. 4B is well over any track's passing threshold on
// Hydration (total issuance ~6.5B) and avoids locking Alice's entire balance
// at Locked6x — which leaves the account unusable for subsequent test ops
// until the conviction period expires. See Ben's note: "only vote with 4B max".
const MAX_VOTE_BASE = 4_000_000_000n * 10n ** 12n;
const WASM_PATH =
  process.env.WASM_PATH ||
  "/Users/yashsharma/Workspace/Hydration/hydration-node/target/release/wbuild/hydradx-runtime/hydradx_runtime.compact.compressed.wasm";

async function signAndWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
          }
          return reject(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
          }
        }
        console.log(`  OK`);
        resolve(events as any[]);
      }
    }).catch(reject);
  });
}

async function main() {
  if (!fs.existsSync(WASM_PATH)) throw new Error(`WASM not found: ${WASM_PATH}`);
  const wasmBytes = fs.readFileSync(WASM_PATH);
  const wasmHex = "0x" + wasmBytes.toString("hex");
  const codeHash = blake2AsHex(wasmBytes, 256);
  console.log(`WASM: ${(wasmBytes.length / 1024 / 1024).toFixed(2)} MB, hash ${codeHash}`);

  const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
  const chain = await api.rpc.system.chain();
  const ver = await api.rpc.state.getRuntimeVersion();
  console.log(`${chain} specVersion=${ver.specVersion}`);

  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  // Inner call: system.authorizeUpgrade(codeHash)
  const innerCall = api.tx.system.authorizeUpgrade(codeHash);
  const innerHash = innerCall.method.hash.toHex();
  console.log(`inner (authorizeUpgrade) hash: ${innerHash}`);

  // Step 1: TC whitelists the inner hash (no-op if already whitelisted)
  const wl: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wl.isSome) {
    const wlCall = api.tx.whitelist.whitelistCall(innerHash);
    await signAndWait(
      api.tx.technicalCommittee.propose(1, wlCall, wlCall.method.encodedLength),
      alice,
      api,
      "TC propose(whitelist.whitelistCall)"
    );
  } else {
    console.log("inner call already whitelisted");
  }

  // Step 2: Wrapper call + note preimage
  const wrapper = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
  const wrapperHex = wrapper.method.toHex();
  const wrapperHash = wrapper.method.hash.toHex();
  const wrapperLen = wrapper.method.encodedLength;
  console.log(`wrapper (dispatchWhitelistedCallWithPreimage) hash: ${wrapperHash}, len: ${wrapperLen}`);

  const pre: any = await api.query.preimage.requestStatusFor(wrapperHash);
  const preOld: any = await api.query.preimage.statusFor(wrapperHash);
  if (!pre.isSome && !preOld.isSome) {
    await signAndWait(
      api.tx.preimage.notePreimage(wrapperHex),
      alice,
      api,
      "preimage.notePreimage(wrapper)"
    );
  } else {
    console.log("wrapper preimage already noted");
  }

  // Step 3: Submit on whitelisted_caller track (1)
  const events = await signAndWait(
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: wrapperHash, len: wrapperLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit(WhitelistedCaller)"
  );
  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no Submitted event");
  console.log(`ref: ${refIndex}`);

  // Step 4: Decision deposit + vote
  await signAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api,
    "referenda.placeDecisionDeposit"
  );

  const bal: any = await api.query.system.account(alice.address);
  const usable = bal.data.free.toBigInt() - bal.data.frozen.toBigInt();
  const buffered = usable > BigInt(10_000) * BigInt(10 ** 12)
    ? usable - BigInt(5_000) * BigInt(10 ** 12)
    : usable;
  const voteBalance = (buffered < MAX_VOTE_BASE ? buffered : MAX_VOTE_BASE).toString();
  console.log(
    `voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX` +
      ` (usable=${Number(usable / 10n ** 12n).toLocaleString()}, cap=4B)`
  );
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote(aye, 6x)"
  );

  // Step 5: Poll for Approved
  console.log(`\npolling ref ${refIndex}...`);
  let approved = false;
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!info.isSome) continue;
    const r = info.unwrap();
    if (r.isApproved) {
      console.log(`  Approved`);
      approved = true;
      break;
    }
    if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled) {
      throw new Error(`${r.type}`);
    }
    if (i % 3 === 0) console.log(`  [${i}] ${r.type}`);
  }
  if (!approved) throw new Error("referendum did not pass in time");

  // Wait for enactment
  await new Promise((r) => setTimeout(r, 15000));

  // Verify authorizedUpgrade is set
  const auth: any = await api.query.system.authorizedUpgrade();
  console.log(`\nsystem.authorizedUpgrade: ${auth.isSome ? JSON.stringify(auth.toHuman()) : "NONE"}`);
  if (!auth.isSome) throw new Error("authorizeUpgrade did not execute");

  // Step 6: Apply the upgrade
  console.log(`\nuploading WASM (${(wasmBytes.length / 1024 / 1024).toFixed(2)} MB)...`);
  await signAndWait(
    api.tx.system.applyAuthorizedUpgrade(wasmHex),
    alice,
    api,
    "system.applyAuthorizedUpgrade"
  );

  // Step 7: Wait for runtime switch
  console.log("\nwaiting for runtime switch...");
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 6000));
    const v = await api.rpc.state.getRuntimeVersion();
    if (v.specVersion.toNumber() >= 406) {
      console.log(`\n✓✓✓ UPGRADED — specVersion now ${v.specVersion}`);
      break;
    }
    if (i % 3 === 0) console.log(`  [${i}] specVersion=${v.specVersion}`);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(`\nFAILED: ${e.message}`);
  process.exit(1);
});
