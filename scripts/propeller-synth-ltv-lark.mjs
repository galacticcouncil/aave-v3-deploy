#!/usr/bin/env node
// Interim fix for the inert synthetic floor on lark-2 (bug B): the synth
// reserve is listed LTV=0 and Aave refuses to enable an LTV-0 asset as
// collateral, so the supplied synth floors nothing and rebalance derives a
// phantom LTV. ONE Root referendum:
//   PoolConfigurator.configureReserveAsCollateral(SYNTH, 100, 9800, 10100)
// dispatched as the GOV aave-manager. NOT retroactive: the live vault
// positions supplied their synth under LTV 0, so they engage only on their
// NEXT synth supply (any new deposit / maintainPeg top-up triggers the
// vault's explicit setUserUseReserveAsCollateral).
//
// usage: node scripts/propeller-synth-ltv-lark.mjs [--live]
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const CONFIGURATOR = "0xE64C38E2Fa00DFe4F1d0B92f75B8E44eBDF292e4";
const POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const SYNTH = "0x23B69fd91a463ECB4B5864e4C2Ec6a20AFEC47b8";
const LTV = 100, LT = 9800, BONUS = 10100;
const HDX = 10n ** 12n;

const cfgI = new ethers.utils.Interface(["function configureReserveAsCollateral(address,uint256,uint256,uint256)"]);
const poolI = new ethers.utils.Interface(["function getConfiguration(address) view returns (uint256)"]);

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
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const ethCall = async (to, d) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, d, "0", "30000000", null, null, null, false, null, null); return r.toJSON(); };
  const evm = (target, data) => api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, target, data, "0", "2000000", "100000000", null, null, [], []));

  const cfg = (j) => { const v = BigInt(poolI.decodeFunctionResult("getConfiguration", j.ok.value)[0]); return { ltv: Number(v & 0xffffn), lt: Number((v >> 16n) & 0xffffn) }; };
  const before = cfg(await ethCall(POOL, poolI.encodeFunctionData("getConfiguration", [SYNTH])));
  console.log(`synth reserve before: LTV ${before.ltv} bps | LT ${before.lt} bps`);
  console.log(`setting LTV ${LTV} / LT ${LT} / bonus ${BONUS}`);

  const inner = api.tx.utility.batchAll([evm(CONFIGURATOR, cfgI.encodeFunctionData("configureReserveAsCollateral", [SYNTH, LTV, LT, BONUS]))]);
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
  const after = cfg(await ethCall(POOL, poolI.encodeFunctionData("getConfiguration", [SYNTH])));
  console.log(`synth reserve after: LTV ${after.ltv} bps | LT ${after.lt} bps`);
  console.log(after.ltv === LTV ? "LTV SET ✓ (live positions engage on their next synth supply)" : "NOT set");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
