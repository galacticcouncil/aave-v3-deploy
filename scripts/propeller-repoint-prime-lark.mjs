#!/usr/bin/env node
// Repoint the AaveOracle PRIME/USD source to the new looper-owned mirror oracle
// on lark-2, via ONE Root referendum:
//   AaveOracle.setAssetSources([PRIME], [NEW_ORACLE])
// dispatched as the GOV aave-manager (AaveOracle owner). After this + the arb
// bot, the money market prices PRIME off a live, bot-synced feed.
//
// usage: node scripts/propeller-repoint-prime-lark.mjs <NEW_ORACLE> [--live]
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const AAVE_ORACLE = "0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760";
const PRIME20 = "0x000000000000000000000000000000010000002B";
const NEW_ORACLE = process.env.NEW_ORACLE || process.argv.find((a) => a.startsWith("0x") && a.length === 42);
const HDX = 10n ** 12n;

const oracleI = new ethers.utils.Interface([
  "function setAssetSources(address[],address[])",
  "function getAssetPrice(address) view returns (uint256)",
  "function getSourceOfAsset(address) view returns (address)",
]);

async function sign(tx, alice, api, label) {
  console.log(`--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => {
    let u;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: "" + dispatchError }; u?.(); return rej(new Error(`${e.section}.${e.name}`)); }
      u?.(); res(events);
    }).then((x) => { u = x; }).catch(rej);
  });
}

async function main() {
  if (!NEW_ORACLE) throw new Error("pass the new oracle address (arg or NEW_ORACLE env)");
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const ethCall = async (to, d) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, d, "0", "30000000", null, null, null, false, null, null); return r.toJSON(); };
  const evm = (target, data) => api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, target, data, "0", "2000000", "100000000", null, null, [], []));

  const srcBefore = oracleI.decodeFunctionResult("getSourceOfAsset", (await ethCall(AAVE_ORACLE, oracleI.encodeFunctionData("getSourceOfAsset", [PRIME20]))).ok.value)[0];
  const priceBefore = BigInt(oracleI.decodeFunctionResult("getAssetPrice", (await ethCall(AAVE_ORACLE, oracleI.encodeFunctionData("getAssetPrice", [PRIME20]))).ok.value)[0]);
  console.log(`PRIME source before: ${srcBefore} | price $${(Number(priceBefore) / 1e8).toFixed(5)}`);
  console.log(`repointing PRIME (${PRIME20}) -> ${NEW_ORACLE}`);

  const inner = api.tx.utility.batchAll([evm(AAVE_ORACLE, oracleI.encodeFunctionData("setAssetSources", [[PRIME20], [NEW_ORACLE]]))]);
  const hex = inner.method.toHex(), hash = inner.method.hash.toHex(), len = inner.method.encodedLength;
  if (!LIVE) { console.log("DRY-RUN — pass --live to submit the referendum"); await api.disconnect(); return; }

  try { await sign(api.tx.preimage.notePreimage(hex), alice, api, "notePreimage"); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; console.log("  already noted"); }
  const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log("  ref #" + ref);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "decisionDeposit");
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) { console.log(`  [${i}] Approved`); break; }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type);
  }
  await new Promise((r) => setTimeout(r, 18000));
  const srcAfter = oracleI.decodeFunctionResult("getSourceOfAsset", (await ethCall(AAVE_ORACLE, oracleI.encodeFunctionData("getSourceOfAsset", [PRIME20]))).ok.value)[0];
  const priceAfter = BigInt(oracleI.decodeFunctionResult("getAssetPrice", (await ethCall(AAVE_ORACLE, oracleI.encodeFunctionData("getAssetPrice", [PRIME20]))).ok.value)[0]);
  console.log(`PRIME source after: ${srcAfter} | price $${(Number(priceAfter) / 1e8).toFixed(5)}`);
  console.log(srcAfter.toLowerCase() === NEW_ORACLE.toLowerCase() ? "REPOINTED ✓" : "NOT repointed");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
