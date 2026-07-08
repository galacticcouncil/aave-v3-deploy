#!/usr/bin/env node
// Max out each Propeller vault's targetLtvBps to its collateral's reserve max
// LTV (read live from the money-market config), via ONE Root referendum:
//   for each vault: Vault.setLtvBand(maxLTV, maxLTV-500, maxLTV+300)
// dispatched as the GOV aave-manager (holder of ADMIN_ROLE).
// usage: node scripts/propeller-maxltv-lark.mjs [--live]
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const HDX = 10n ** 12n;
const BAND_LOW = 500, BAND_HIGH = 300;

// vault -> collateral ERC20 (reserve key for the mm config)
const VAULTS = [
  { sym: "ETH",  vault: "0x305EE427b94187c5abC68fCCc194E77D82F39921", coll: "0x0000000000000000000000000000000100000022" },
  { sym: "tBTC", vault: "0x8E84b6e1eFfdF6C3258854ED2E813b1882b719Bf", coll: "0x00000000000000000000000000000001000f453d" },
];
const POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";

const cfgI = new ethers.utils.Interface(["function getConfiguration(address) view returns (tuple(uint256 data))"]);
const vaultI = new ethers.utils.Interface(["function setLtvBand(uint16,uint16,uint16)", "function targetLtvBps() view returns (uint16)"]);

async function sign(tx, alice, api) {
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

  const inner = [];
  for (const v of VAULTS) {
    const r = await ethCall(POOL, cfgI.encodeFunctionData("getConfiguration", [v.coll]));
    const data = BigInt(cfgI.decodeFunctionResult("getConfiguration", r.ok.value)[0].data);
    const maxLtv = Number(data & 0xFFFFn);
    const cur = Number(BigInt((await ethCall(v.vault, vaultI.encodeFunctionData("targetLtvBps", []))).ok.value));
    const target = maxLtv, low = Math.max(0, maxLtv - BAND_LOW), high = maxLtv + BAND_HIGH;
    console.log(`${v.sym}: mm maxLTV=${maxLtv} | current target=${cur} -> set ${target} (band ${low}/${high})`);
    inner.push(evm(v.vault, vaultI.encodeFunctionData("setLtvBand", [target, low, high])));
  }

  const batch = api.tx.utility.batchAll(inner);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  console.log(`batch: ${inner.length} setLtvBand calls, ${len} bytes`);
  if (!LIVE) { console.log("DRY-RUN — pass --live to submit the referendum"); await api.disconnect(); return; }

  try { await sign(api.tx.preimage.notePreimage(hex), alice, api); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
  const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api);
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log("ref #" + ref);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api);
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api);
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) { console.log(`[${i}] Approved`); break; }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type);
  }
  await new Promise((r) => setTimeout(r, 18000));
  for (const v of VAULTS) {
    const cur = Number(BigInt((await ethCall(v.vault, vaultI.encodeFunctionData("targetLtvBps", []))).ok.value));
    console.log(`${v.sym} targetLtvBps now: ${cur}`);
  }
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
