#!/usr/bin/env node
// register the aPRIME (1043) router route so the DCA can PRICE it for the unwind
// budget valuation. aPRIME trades in no pool, so OraclePriceProviderUsingRoute
// has nothing to quote → dca.CalculatingPriceError on requestRedeem. aPRIME is
// 1:1 with PRIME via the Aave pool, so the route is a single Aave hop 1043→43;
// PRIME (43) is already priceable to native. via Root forceInsertRoute.
//
// THIS IS A DEPLOYMENT REQUIREMENT — without it the unwind/redeem path can't price.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const VAULT = "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const HDX = 10n ** 12n;
const vI = new ethers.utils.Interface(["function requestRedeem(uint256,address) returns (uint256)"]);
// aPRIME→PRIME (single Aave hop). full native path as fallback if needed.
const ROUTE_SIMPLE = [{ pool: { Aave: null }, assetIn: 1043, assetOut: 43 }];
const ROUTE_FULL = [{ pool: { Aave: null }, assetIn: 1043, assetOut: 43 }, { pool: { Stableswap: 143 }, assetIn: 43, assetOut: 222 }, { pool: { Omnipool: null }, assetIn: 222, assetOut: 0 }];
const USE_FULL = process.argv.includes("--full");

async function sign(tx, alice, api) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => { let u; tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
    if (!(status.isInBlock || status.isFinalized)) return;
    if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: "" + dispatchError }; u?.(); return rej(new Error(`${e.section}.${e.name}`)); }
    u?.(); res(events); }).then((x) => { u = x; }).catch(rej); });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const route = USE_FULL ? ROUTE_FULL : ROUTE_SIMPLE;
  const assetPair = USE_FULL ? { assetIn: 1043, assetOut: 0 } : { assetIn: 1043, assetOut: 43 };
  const inner = api.tx.router.forceInsertRoute(assetPair, route);
  console.log(`route ${JSON.stringify(assetPair)} = ${JSON.stringify(route)}`);

  const ethSim = async () => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, VAULT, vI.encodeFunctionData("requestRedeem", [(10n * 10n ** 18n).toString(), ALICE_EVM]), "0", "8000000", null, null, null, false, null, null); return r.toJSON(); };
  console.log("requestRedeem SIM before:", JSON.stringify((await ethSim())?.ok?.exitReason ?? {}));
  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  // Root referendum carrying forceInsertRoute
  const hex = inner.method.toHex(), hash = inner.method.hash.toHex(), len = inner.method.encodedLength;
  try { await sign(api.tx.preimage.notePreimage(hex), alice, api); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
  const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api);
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log(`ref #${ref}`);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api);
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api);
  for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) break; if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
  await new Promise((r) => setTimeout(r, 18000));
  const got = await api.query.router.routes(assetPair);
  console.log("route registered:", got.isSome ? "yes" : "no");
  const sim = await ethSim();
  const ok = JSON.stringify(sim?.ok?.exitReason ?? {}).match(/ucceed/);
  console.log("requestRedeem SIM after:", JSON.stringify(sim?.ok?.exitReason ?? sim), ok ? "→ PRICEABLE ✓" : "→ still failing");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
