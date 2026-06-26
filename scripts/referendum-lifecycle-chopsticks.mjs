// Full Whitelisted-Caller (track 1) referendum lifecycle on a chopsticks fork.
// Drives every governance extrinsic via Root-scheduler injection + utility.dispatchAs
// (the proven, reliable chopsticks pattern — no signAndSend). Faithful calls:
// TC whitelist, referenda.submit (Origins::WhitelistedCaller), placeDecisionDeposit,
// convictionVoting.vote, nudgeReferendum. Time is COMPRESSED via storage surgery
// (deciding/confirming set in the past); the ENACTMENT is performed by the chain's
// own scheduler, proving the track-1 path dispatches the whitelisted recovery as Root.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { compactToU8a, hexToU8a, u8aToHex, u8aConcat } from "@polkadot/util";

const WS = process.env.WS || "ws://127.0.0.1:8011";
const INNER =
  "0x0d02104f0245544800cb7cb885475f9f440139b22f4dc051c0f554d6e800000000000000002e00000000001ce7e31f8d328d010000000000004f02455448006612da77c65bbb9b27120bb155f4069505a5e58800000000000000002e000000e5eac6378fa18c5f64000000000000004f02455448004d7382b3c29b0726cb9c280ce313f6ab481b657c00000000000000002e0000003da33461fbcdbeb0320000000000000001050c0101e38f185207498abb5c213d0fb059b3d8d499693d59a5a8e17fe4824942a77f4696fc550c316a33d461919d3bbcba3d399559224496d1f5c9e8cfd7ebc6dcf0810101e38f185207498abb5c213d0fb059b3d8d499693d59a5a8e17fe4824942a77f46e0185f386e65f1c623ce4415af1dc3b1c3be2d65a6f4640f5506d3dbf8cd91a20101e38f185207498abb5c213d0fb059b3d8d499693d59a5a8e17fe4824942a77f465062965aba4a0d1dce164535a11d6fd2a099125442231c671facaf25f12f6083";
const ASSET = 46;
const HDX = 10n ** 12n;

async function main() {
  const provider = new WsProvider(WS, 2500, {}, 600000);
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);
  const newBlock = (n = 1) => send("dev_newBlock", [{ count: n }]);
  const head = async () => (await api.rpc.chain.getHeader()).number.toNumber();
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const log = (...a) => { console.log(...a); };
  console.log(`Connected ${await api.rpc.system.chain()} @ #${await head()}`);

  // Inject a call as Root via preimage + Scheduler at head+1, mine it, return events.
  async function rootExec(callHex, label) {
    const hash = blake2AsHex(callHex), len = (callHex.length - 2) / 2, body = hexToU8a(callHex);
    await send("dev_setStorage", [[[api.query.preimage.preimageFor.key([hash, len]), u8aToHex(u8aConcat(compactToU8a(body.length), body))]]]);
    const sName = api.query.preimage.requestStatusFor ? "RequestStatusFor" : "StatusFor";
    await send("dev_setStorage", [{ Preimage: { [sName]: [[[hash], { Requested: { maybeTicket: null, count: 1, maybeLen: len } }]] } }]);
    const t = (await head()) + 1;
    await send("dev_setStorage", [{ Scheduler: { Agenda: [[[t], [{ maybeId: null, priority: 0, call: { Lookup: { hash_: hash, len } }, maybePeriodic: null, origin: { system: "Root" } }]]] } }]);
    await newBlock();
    const evs = await (await api.at((await api.rpc.chain.getBlockHash(t)).toHex())).query.system.events();
    let bad = null;
    for (const { event } of evs) {
      const k = `${event.section}.${event.method}`;
      if (/(ExtrinsicFailed|BatchInterrupted|DispatchedAs|CallUnavailable|MemberDispatchFailed)/i.test(k)) bad = `${k} ${JSON.stringify(event.data.toJSON())}`;
    }
    log(`  [root] ${label} @#${t}${bad ? "  ⚠ " + bad : ""}`);
    return evs;
  }
  const dispatchAs = (call) => api.tx.utility.dispatchAs({ system: { signed: alice.address } }, call);

  const inner = api.createType("Call", INNER);
  const innerHash = blake2AsHex(INNER);
  const whos = [], trapKeys = [];
  for (const c of inner.args[0]) {
    if (c.section === "currencies" && c.method === "updateBalance") whos.push(c.args[0].toString());
    else if (c.section === "system" && c.method === "killStorage") for (const k of c.args[0]) trapKeys.push(k.toHex());
  }
  const dispatch = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(inner);
  const dHex = dispatch.method.toHex(), dHash = blake2AsHex(dHex), dLen = (dHex.length - 2) / 2;
  const balOf = async (w) => (await api.query.tokens.accounts(w, ASSET)).free.toString();

  // 0) fund Alice (dev_setStorage) + seed trap keys so killStorage is observable
  await send("dev_setStorage", [{ System: { Account: [[[alice.address], { providers: 1, data: { free: (50_000_000n * HDX).toString(), reserved: "0", frozen: "0", flags: "170141183460469231731687303715884105728" } }]] } }]);
  for (const k of trapKeys) await send("dev_setStorage", [[[k, "0x01000000"]]]);
  const before = []; for (const w of whos) before.push(await balOf(w));
  log(`Funded Alice; seeded ${trapKeys.length} traps; ${whos.length} beneficiaries`);

  // 1) TC leg: whitelist the inner call hash (Root == WhitelistOrigin)
  await rootExec(api.tx.whitelist.whitelistCall(innerHash).method.toHex(), "whitelist.whitelistCall");
  log(`  whitelisted on-chain: ${(await api.query.whitelist.whitelistedCall(innerHash)).isSome}`);

  // 2) notePreimage(dispatch) + referenda.submit, both as Alice (via Root->dispatchAs)
  const subEvs = await rootExec(
    api.tx.utility.batchAll([
      dispatchAs(api.tx.preimage.notePreimage(dHex)),
      dispatchAs(api.tx.referenda.submit({ Origins: "WhitelistedCaller" }, { Lookup: { hash: dHash, len: dLen } }, { After: 100 })),
    ]).method.toHex(), "notePreimage + referenda.submit");
  let refIndex = null;
  for (const { event } of subEvs) if (event.section === "referenda" && event.method === "Submitted") refIndex = event.data[0].toNumber();
  const trk = (await api.query.referenda.referendumInfoFor(refIndex)).unwrap().asOngoing.track.toNumber();
  log(`  referendum #${refIndex} on track ${trk} (1 = whitelisted_caller)`);

  // 3) decision deposit (50k HDX) + aye vote
  await rootExec(
    api.tx.utility.batchAll([
      dispatchAs(api.tx.referenda.placeDecisionDeposit(refIndex)),
      dispatchAs(api.tx.convictionVoting.vote(refIndex, { Standard: { vote: { aye: true, conviction: "Locked1x" }, balance: (1_000_000n * HDX).toString() } })),
    ]).method.toHex(), "placeDecisionDeposit + vote");
  log(`  decision deposit placed + aye voted`);

  // 4) COMPRESS TIME: rewrite Ongoing -> deciding now, confirm period elapsed, passing tally
  const info = (await api.query.referenda.referendumInfoFor(refIndex)).unwrap();
  const og = info.asOngoing, h = await head(), BIG = (5_000_000_000n * HDX).toString();
  const newOg = api.registry.createType(og.toRawType(), {
    track: og.track, origin: og.origin, proposal: og.proposal, enactment: og.enactment,
    submitted: og.submitted, submissionDeposit: og.submissionDeposit, decisionDeposit: og.decisionDeposit,
    deciding: { since: h - 1, confirming: h - 2402 }, tally: { ayes: BIG, nays: 0, support: BIG }, inQueue: false, alarm: null,
  });
  await send("dev_setStorage", [[[api.query.referenda.referendumInfoFor.key(refIndex), api.registry.createType(info.toRawType(), { Ongoing: newOg }).toHex()]]]);
  log(`  [surgery] deciding.since=${h - 1}, confirming=${h - 2402} (elapsed), tally passing`);

  // 5) nudge -> Confirmed/Approved + schedules the call at enactment (After 100)
  const nEvs = await rootExec(dispatchAs(api.tx.referenda.nudgeReferendum(refIndex)).method.toHex(), "nudgeReferendum");
  for (const { event } of nEvs) if (event.section === "referenda" && /Confirmed|Approved|DecisionStarted/.test(event.method)) log(`  referenda.${event.method} ${JSON.stringify(event.data.toJSON())}`);
  log(`  referendum state: ${Object.keys((await api.query.referenda.referendumInfoFor(refIndex)).toJSON())[0]}`);

  // 6) find the scheduled enactment (the CHAIN scheduled it) and relocate to head+1
  let target = null;
  for (const [k, v] of await api.query.scheduler.agenda.entries())
    for (const t of v) if (t.isSome && t.unwrap().call.isLookup && t.unwrap().call.asLookup.hash_.toHex() === dHash) target = k.args[0].toNumber();
  log(`  scheduler enactment queued at #${target}`);
  if (!target) { log("  !! not scheduled — referendum did not approve"); await api.disconnect(); return; }
  const aVal = (await api.rpc.state.getStorage(api.query.scheduler.agenda.key(target))).unwrap().toHex();
  const enactAt = (await head()) + 1;
  await send("dev_setStorage", [[[api.query.scheduler.agenda.key(enactAt), aVal]]]);
  await newBlock();
  log(`  relocated enactment to #${enactAt}; observing scheduler dispatch:`);
  for (const { event } of await (await api.at((await api.rpc.chain.getBlockHash(enactAt)).toHex())).query.system.events()) {
    const k = `${event.section}.${event.method}`;
    if (/Dispatched|Deposited|WhitelistedCallDispatched|Failed|Unavailable/i.test(k)) log(`   @#${enactAt} ${k} ${JSON.stringify(event.data.toJSON())}`);
  }

  // 7) verify
  const after = []; for (const w of whos) after.push(await balOf(w));
  const traps = []; for (const k of trapKeys) traps.push((await api.rpc.state.getStorage(k)).isSome);
  log(`\n=== RESULT (full referendum lifecycle) ===`);
  for (let i = 0; i < whos.length; i++) log(`  ${whos[i]}  +${(Number(BigInt(after[i]) - BigInt(before[i])) / 1e18).toFixed(2)} apyUSD`);
  log(`  traps present after: ${JSON.stringify(traps)} (expect all false)`);
  const minted = whos.every((_, i) => BigInt(after[i]) > BigInt(before[i])), cleared = traps.every((x) => x === false);
  log(`\n  MINTED via referendum : ${minted}`);
  log(`  TRAPS CLEARED         : ${cleared}`);
  log(`  LIFECYCLE ENACTED     : ${minted && cleared}`);
  await api.disconnect();
}
main().catch((e) => { console.error("FATAL", e.message || e); process.exit(1); });
