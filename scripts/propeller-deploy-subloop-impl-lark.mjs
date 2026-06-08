#!/usr/bin/env node
// Deploy a fresh SubLoop implementation on lark-2 via evm.create from //Alice's
// EVM mirror (0xd435…). No proxy, no init — UUPS impl is just the bytecode. The
// forge deployer key (0x222222b6…) isn't in this env, and Alice's H160 has no
// secp256k1 key, so this goes through the substrate evm pallet rather than forge.
// Prints the new impl address for scripts/propeller-upgrade-subloop-lark.mjs.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";
import { readFileSync } from "node:fs";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const ARTIFACT = "propeller-vault/out/SubLoop.sol/SubLoop.json";
const GAS_LIMIT = "8000000";
const MAX_FEE = "100000000";

async function sign(tx, alice, api) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => {
    let u;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule
          ? api.registry.findMetaError(dispatchError.asModule)
          : { section: "", name: "" + dispatchError };
        u?.();
        return rej(new Error(`${e.section}.${e.name}`));
      }
      u?.();
      res(events);
    }).then((x) => { u = x; }).catch(rej);
  });
}

async function main() {
  const bytecode = JSON.parse(readFileSync(ARTIFACT, "utf8")).bytecode.object;
  console.log("init code:", (bytecode.length - 2) / 2, "bytes");

  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  // predict the CREATE address from Alice's EVM nonce.
  const nonce = await api.rpc.eth.getTransactionCount(ALICE_EVM).catch(() => null);
  const predicted = nonce != null
    ? ethers.utils.getContractAddress({ from: ALICE_EVM, nonce: nonce.toNumber() })
    : "?";
  console.log("deployer:", ALICE_EVM, "nonce:", nonce?.toNumber?.() ?? "?", "→ predicted impl:", predicted);

  if (!LIVE) { console.log("DRY-RUN — pass --live to broadcast"); await api.disconnect(); return; }

  const tx = api.tx.evm.create(ALICE_EVM, bytecode, "0", GAS_LIMIT, MAX_FEE, null, null, [], []);
  const events = await sign(tx, alice, api);

  let created = null, failed = null;
  for (const { event } of events) {
    if (event.section === "evm" && event.method === "Created") created = event.data[0].toString();
    if (event.section === "evm" && (event.method === "CreatedFailed" || event.method === "ExecutedFailed")) failed = event.toHuman();
  }
  if (failed) throw new Error("evm create failed: " + JSON.stringify(failed));
  const addr = created || predicted;
  console.log("impl deployed:", addr);

  // verify code landed.
  const code = await api.rpc.eth.getCode(addr).catch(() => null);
  const len = code ? (code.toHex().length - 2) / 2 : 0;
  console.log("deployed code:", len, "bytes", len > 0 ? "✓" : "✗ (empty — deploy reverted)");
  if (len === 0) process.exitCode = 1;

  console.log("\nnext: node scripts/propeller-upgrade-subloop-lark.mjs " + addr + " --live");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
