#!/usr/bin/env node
// Raise the SubLoop deploy/unwind router-swap slippage tolerance via governance
// configureDca (no redeploy). The deploy minOut assumes HOLLAR≈PRIME oracle-fair,
// but pool-143's actual HOLLAR->PRIME rate is ~1.1% worse -> router.TradingLimitReached
// at the 1% default. Raise dcaSlippagePpm to 8% (80000). Deployed SubLoop uses the
// 5-arg configureDca(hollar, prime, aPrime, primePoolId, slippagePpm).
//   node scripts/propeller-bump-slippage-lark4.mjs            # dry-run
//   node scripts/propeller-bump-slippage-lark4.mjs --live     # submit + vote + enact
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = process.env.PROPOSAL_WS || "wss://4.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const SUBLOOP = process.env.SUBLOOP || "0x8F790900596a2172F307250389CEEF3923B56ec6";
const SLIP = Number(process.env.SLIPPAGE_PPM || 80000); // 8%
const HDX = 10n ** 12n;
const sl = new ethers.utils.Interface(["function configureDca(uint32,uint32,uint32,uint32,uint32)", "function dcaSlippagePpm() view returns (uint32)"]);
const ec = (api, d) => api.call.ethereumRuntimeRPCApi.call("0xd43593c715fdd31c61141abd04a99fd6822c8558", SUBLOOP, d, "0", "2000000", null, null, null, false, null, null).then(r => r.toJSON()?.ok?.value ?? "0x");
const slip = async (api) => { const v = await ec(api, sl.encodeFunctionData("dcaSlippagePpm", [])); return v === "0x" ? "?" : BigInt(v).toString(); };

async function signAndWait(tx, signer, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(signer.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(signer, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() }; unsub?.(); return reject(new Error(`${e.section}.${e.name}`)); }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const call = api.tx.evm.call(GOV, SUBLOOP, sl.encodeFunctionData("configureDca", [222, 43, 1043, 143, SLIP]), "0", "600000", "100000000", null, null, [], []);
  const batch = api.tx.utility.batchAll([api.tx.dispatcher.dispatchAsAaveManager(call)]);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  console.log(`ws=${WS} live=${LIVE} subloop=${SUBLOOP} — configureDca(222,43,1043,143,${SLIP})`);
  console.log("  dcaSlippagePpm before:", await slip(api));
  if (!LIVE) { console.log("\nDRY-RUN — not broadcasting."); await api.disconnect(); return; }
  try { await signAndWait(api.tx.preimage.notePreimage(hex), alice, api, "notePreimage"); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; console.log("  already noted"); }
  const ev = await signAndWait(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
  let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log("  referendum #" + ref);
  await signAndWait(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "deposit");
  await signAndWait(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
  for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) { console.log(`  [${i}] Approved`); break; } if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error(`ref ${info.type}`); }
  process.stdout.write("  awaiting enactment");
  for (let i = 0; i < 40; i++) { if ((await slip(api)) === String(SLIP)) break; process.stdout.write("."); await new Promise((r) => setTimeout(r, 3000)); }
  console.log("\n  dcaSlippagePpm after:", await slip(api));
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
