// Runtime upgrade on lark 1 — reuses the already-noted preimage for
// system.authorizeUpgrade, submits on Root track, Alice votes, waits for
// Approved, then calls system.applyAuthorizedUpgrade with the WASM bytes.
//
// Mirrors scripts/proxy-fee-test/scripts/deploy-lark.js on hydration-node but
// with sign-and-wait that resolves on isFinalized (not isInBlock) and fail-fast
// ExtrinsicFailed handling — same pattern as our working whitelist scripts.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import * as fs from "fs";

const LARK_WS = process.env.WS_URL || "wss://1.lark.hydration.cloud";
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
  if (!fs.existsSync(WASM_PATH)) {
    throw new Error(`WASM not found at ${WASM_PATH}`);
  }
  const wasmBytes = fs.readFileSync(WASM_PATH);
  const wasmHex = "0x" + wasmBytes.toString("hex");
  const codeHash = blake2AsHex(wasmBytes, 256);
  console.log(`WASM size: ${(wasmBytes.length / 1024 / 1024).toFixed(2)} MB`);
  console.log(`Code hash: ${codeHash}`);

  const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
  const chainName = await api.rpc.system.chain();
  const ver = await api.rpc.state.getRuntimeVersion();
  console.log(`Connected: ${chainName} specVersion=${ver.specVersion}`);

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  // 1. Ensure preimage of system.authorizeUpgrade(codeHash) is noted
  const authorizeCall = api.tx.system.authorizeUpgrade(codeHash);
  const encodedCall = authorizeCall.method.toHex();
  const encodedHash = blake2AsHex(encodedCall);
  const encodedLen = (encodedCall.length - 2) / 2;
  console.log(`authorizeUpgrade preimage hash: ${encodedHash}, len: ${encodedLen}`);

  const preReq: any = await api.query.preimage.requestStatusFor(encodedHash);
  const preStat: any = await api.query.preimage.statusFor(encodedHash);
  if (!preReq.isSome && !preStat.isSome) {
    await signAndWait(
      api.tx.preimage.notePreimage(encodedCall),
      alice,
      api,
      "preimage.notePreimage(authorizeUpgrade)"
    );
  } else {
    console.log("\npreimage already noted");
  }

  // 2. Submit referendum on Root track (track 0)
  const events = await signAndWait(
    api.tx.referenda.submit(
      { system: "Root" },
      { Lookup: { hash: encodedHash, len: encodedLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit(Root)"
  );
  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no referendum Submitted event");
  console.log(`Referendum index: ${refIndex}`);

  // 3. Decision deposit
  await signAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api,
    "referenda.placeDecisionDeposit"
  );

  // 4. Vote aye with full conviction (6x) — Root track needs strong support
  const bal: any = await api.query.system.account(alice.address);
  const voteBalance = (
    bal.data.free.toBigInt() - BigInt(10_000_000) * BigInt(10 ** 12)
  ).toString();
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: {
        vote: { aye: true, conviction: "Locked6x" },
        balance: voteBalance,
      },
    }),
    alice,
    api,
    "convictionVoting.vote(aye, Locked6x)"
  );

  // 5. Poll for Approved
  console.log(`\nPolling referendum ${refIndex}...`);
  let approved = false;
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!info.isSome) continue;
    const ref = info.unwrap();
    if (ref.isApproved) {
      console.log(`  [${i}] Approved`);
      approved = true;
      break;
    }
    if (ref.isRejected || ref.isCancelled || ref.isTimedOut || ref.isKilled) {
      throw new Error(`Referendum ${refIndex} ${ref.type}`);
    }
    if (i % 3 === 0) {
      if (ref.isOngoing) {
        const o = ref.asOngoing;
        const conf = !o.deciding.isNone && o.deciding.unwrap().confirming;
        console.log(`  [${i}] ongoing (confirming=${conf ? conf.toString() : "no"})`);
      } else {
        console.log(`  [${i}] ${ref.type}`);
      }
    }
  }
  if (!approved) throw new Error("Referendum did not pass in time");

  // 6. Apply the upgrade (anyone can submit this)
  console.log(`\nApplying upgrade — uploading ${(wasmBytes.length / 1024 / 1024).toFixed(2)} MB WASM...`);
  await signAndWait(
    api.tx.system.applyAuthorizedUpgrade(wasmHex),
    alice,
    api,
    "system.applyAuthorizedUpgrade"
  );

  // 7. Wait for runtime switch
  console.log("\nWaiting for runtime upgrade...");
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 6000));
    const v = await api.rpc.state.getRuntimeVersion();
    console.log(`  [${i}] specVersion=${v.specVersion}`);
    if (v.specVersion.toNumber() >= 406) {
      console.log(`\n✓ Runtime upgraded to specVersion ${v.specVersion}`);
      break;
    }
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(`\nFAILED: ${e.message}`);
  process.exit(1);
});
