#!/usr/bin/env node
// drive the Propeller withdraw flow on real lark2 as //Alice (0xd435):
//   1. grant KEEPER to Alice on the VAULT (one Root referendum; she already has
//      KEEPER on the SubLoop from the ramp).
//   2. vault.requestRedeem(shares, alice) — escrows pETH, internally calls
//      subLoop.requestUnwind(slice) which schedules the aPRIME→HOLLAR unwind DCA.
//   3. over blocks: subLoop.pokeRepay() (repay loop debt, free equity HOLLAR) +
//      vault.pokeSettle() (pull freed HOLLAR, repay Main debt, burn synth,
//      withdraw collateral, mark the request claimable) — the deleveraging spiral.
//   4. vault.claim(requestId, alice) → ETH back.
//
// usage: node scripts/propeller-redeem-lark.mjs [--live] [redeemPeth]

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
// pETH amount (18dp) — supports decimals, e.g. "0.297"
const _ra = process.argv.find((a) => /^\d*\.?\d+$/.test(a)) || "10";
const REDEEM = BigInt(Math.round(parseFloat(_ra) * 1e6)) * 10n ** 12n;
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const ALICE_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const VAULT = process.env.VAULT || "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const SUBLOOP = process.env.SUBLOOP || "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const ETH_ASSET = 34;
const HDX = 10n ** 12n;
const KEEPER = ethers.utils.id("KEEPER_ROLE");

const vI = new ethers.utils.Interface([
  "function requestRedeem(uint256,address) returns (uint256)", "function pokeSettle()",
  "function claim(uint256,address) returns (uint256)", "function queueTail() view returns (uint256)",
  // MUST match Redemption in CollateralVault.sol field-for-field. `sharesBurned`
  // was added between collateralSettled and active; omitting it silently decoded
  // sharesBurned AS `active` — which reads false before the first partial claim,
  // so the spiral broke out on iteration 0 and the script reported a completed
  // redemption after settling ~20% of it.
  "function redemptions(uint256) view returns (address owner,uint256 shares,uint256 collateralOwed,uint256 debtShare,uint256 synthShare,uint256 repaid,uint256 collateralSettled,uint256 sharesBurned,bool active)",
  "function balanceOf(address) view returns (uint256)", "function grantRole(bytes32,address)", "function hasRole(bytes32,address) view returns (bool)",
]);
const slI = new ethers.utils.Interface(["function pokeRepay()", "function healthFactor() view returns (uint256)", "function totalEquity() view returns (uint256)"]);

async function sign(tx, alice, api, label) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() }; unsub?.(); return reject(new Error(`${e.section}.${e.name}`)); }
      let failed = "";
      for (const { event } of events) if (event.section === "evm" && event.method === "ExecutedFailed") failed = JSON.stringify(event.data.toJSON()).slice(0, 140);
      unsub?.(); resolve({ events, failed });
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const evmCall = (to, data, gas) => api.tx.evm.call(ALICE_EVM, to, data, "0", gas, "600000000", null, null, [], []);
  const ethCall = async (to, data) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "12000000", null, null, null, false, null, null); return r.toJSON()?.ok?.value ?? "0x"; };
  const num = (v) => (v && v !== "0x" ? BigInt(v) : 0n);
  const ethFree = async () => (await api.query.tokens.accounts(ALICE_SS58, ETH_ASSET)).free.toBigInt();
  const pethBal = async () => num(await ethCall(VAULT, vI.encodeFunctionData("balanceOf", [ALICE_EVM])));
  const hasVaultKeeper = async () => num(await ethCall(VAULT, vI.encodeFunctionData("hasRole", [KEEPER, ALICE_EVM]))) === 1n;
  const red = async (id) => { const d = vI.decodeFunctionResult("redemptions", await ethCall(VAULT, vI.encodeFunctionData("redemptions", [id]))); return { owner: d.owner, shares: BigInt(d.shares.toString()), collateralOwed: BigInt(d.collateralOwed.toString()), debtShare: BigInt(d.debtShare.toString()), repaid: BigInt(d.repaid.toString()), collateralSettled: BigInt(d.collateralSettled.toString()), sharesBurned: BigInt(d.sharesBurned.toString()), active: d.active }; };
  // BigInt `/` truncates, so `x / 10n**18n` prints 0.5 ETH as "0" and a 0.0196
  // ETH return as "+0". Format properly or every readout lies about small amounts.
  const fmt = (v, dec = 18, places = 6) => (Number(v) / 10 ** dec).toFixed(places);

  console.log(`pETH balance: ${fmt(await pethBal())} | redeeming ${fmt(REDEEM)} | ETH free: ${fmt(await ethFree())} | vaultKeeper(alice): ${await hasVaultKeeper()}`);
  if (!LIVE) { console.log("DRY-RUN"); await api.disconnect(); return; }

  // 1. grant KEEPER on the vault to Alice (Root referendum) if missing
  if (!(process.env.SKIP_KEEPER === "1") && !(await hasVaultKeeper())) {
    console.log("\ngranting KEEPER on VAULT to Alice via Root referendum...");
    const aaveMgr = api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, VAULT, vI.encodeFunctionData("grantRole", [KEEPER, ALICE_EVM]), "0", "600000", "100000000", null, null, [], []));
    const batch = api.tx.utility.batchAll([aaveMgr]);
    const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
    try { await sign(api.tx.preimage.notePreimage(hex), alice, api, "note"); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
    const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
    let ref = null; for (const { event } of ev.events) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
    console.log(`  ref #${ref}`);
    await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "dep");
    await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
    for (let i = 0; i < 80; i++) { await new Promise((r) => setTimeout(r, 3000)); const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap(); if (info.isApproved) break; if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type); }
    await new Promise((r) => setTimeout(r, 18000));
    console.log(`  vaultKeeper(alice): ${await hasVaultKeeper()}`);
  }

  // 2. requestRedeem — resume an existing active Alice request if one is queued
  //    (a prior run created one), else create a new one at queueTail.
  const qTail = num(await ethCall(VAULT, vI.encodeFunctionData("queueTail", [])));
  let requestId = null;
  for (let id = 0n; id < qTail; id++) { const rr0 = await red(id); if (rr0.active && rr0.owner.toLowerCase() === ALICE_EVM) { requestId = id; break; } }
  if (requestId === null) {
    requestId = qTail;
    console.log(`\nrequestRedeem(${REDEEM / 10n ** 18n} pETH) → requestId ${requestId}`);
    const rr = await sign(evmCall(VAULT, vI.encodeFunctionData("requestRedeem", [REDEEM.toString(), ALICE_EVM]), "8000000"), alice, api, "requestRedeem");
    if (rr.failed) { console.log("  requestRedeem FAILED:", rr.failed); await api.disconnect(); return; }
  } else {
    console.log(`\nresuming existing requestId ${requestId}`);
  }
  let r = await red(requestId);
  console.log(`  queued: shares=${fmt(r.shares)} collateralOwed=${fmt(r.collateralOwed)} debtShare=${fmt(r.debtShare)} active=${r.active}`);

  // 3. deleveraging spiral: advance blocks for the unwind DCA, then pokeRepay + pokeSettle
  for (let i = 0; i < 12; i++) {
    // router swaps are synchronous (no DCA period to wait for); pokeRepay sells
    // an HF-safe aPRIME sliver each call, so just iterate block-to-block.
    const pr = await sign(evmCall(SUBLOOP, slI.encodeFunctionData("pokeRepay", []), "12000000"), alice, api, `pokeRepay${i}`);
    const ps = await sign(evmCall(VAULT, vI.encodeFunctionData("pokeSettle", []), "12000000"), alice, api, `pokeSettle${i}`);
    r = await red(requestId);
    const hf = num(await ethCall(SUBLOOP, slI.encodeFunctionData("healthFactor", [])));
    console.log(`  spiral${i}: settled=${fmt(r.collateralSettled)} ETH, repaid=${fmt(r.repaid)}/${fmt(r.debtShare)}, active=${r.active}, subloopHF=${hf === 0n ? "·" : (Number(hf) / 1e18).toFixed(4)}${pr.failed ? " repayFAIL" : ""}${ps.failed ? " settleFAIL" : ""}`);
    if (!r.active) break; // request closed out — nothing left to settle
    if (r.repaid >= r.debtShare) break; // debt fully repaid; remaining collateral is claimable
  }

  // 4. claim
  const ethBefore = await ethFree();
  r = await red(requestId);
  if (r.collateralSettled === 0n) { console.log("\nnothing settled yet — unwind still in progress; re-run to continue the spiral"); await api.disconnect(); return; }
  console.log(`\nclaim(requestId ${requestId}) — settled ${fmt(r.collateralSettled)} ETH`);
  const cl = await sign(evmCall(VAULT, vI.encodeFunctionData("claim", [requestId.toString(), ALICE_EVM]), "4000000"), alice, api, "claim");
  if (cl.failed) { console.log("  claim FAILED:", cl.failed); await api.disconnect(); return; }
  const ethAfter = await ethFree();
  console.log(`  ETH free: ${fmt(ethBefore)} → ${fmt(ethAfter)} (+${fmt(ethAfter - ethBefore)} ETH returned)`);
  console.log("REDEEM→CLAIM ✓");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
