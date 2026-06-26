// Enact a hex-encoded inner call via the *Whitelisted Caller* governance path
// on a chopsticks fork (not raw Root). Mirrors the real two-step flow:
//   1. whitelist.whitelistCall(hash)            -- WhitelistOrigin (Root satisfies it)
//   2. whitelist.dispatchWhitelistedCallWithPreimage(call)
//                                               -- Origins::WhitelistedCaller
// Both steps are injected via preimage + Scheduler::Agenda (the proven chopsticks
// trick), each with its correct origin. Then we verify the inner effects:
// apyUSD (asset 46) balances of the beneficiaries + removal of the 3 trap keys.
import { ApiPromise, WsProvider } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { compactToU8a, hexToU8a, u8aToHex, u8aConcat } from "@polkadot/util";

const WS = process.env.WS || "ws://127.0.0.1:8011";
const INNER =
  "0x0d02104f0245544800cb7cb885475f9f440139b22f4dc051c0f554d6e800000000000000002e00000000001ce7e31f8d328d010000000000004f02455448006612da77c65bbb9b27120bb155f4069505a5e58800000000000000002e000000e5eac6378fa18c5f64000000000000004f02455448004d7382b3c29b0726cb9c280ce313f6ab481b657c00000000000000002e0000003da33461fbcdbeb0320000000000000001050c0101e38f185207498abb5c213d0fb059b3d8d499693d59a5a8e17fe4824942a77f4696fc550c316a33d461919d3bbcba3d399559224496d1f5c9e8cfd7ebc6dcf0810101e38f185207498abb5c213d0fb059b3d8d499693d59a5a8e17fe4824942a77f46e0185f386e65f1c623ce4415af1dc3b1c3be2d65a6f4640f5506d3dbf8cd91a20101e38f185207498abb5c213d0fb059b3d8d499693d59a5a8e17fe4824942a77f465062965aba4a0d1dce164535a11d6fd2a099125442231c671facaf25f12f6083";
const ASSET = 46;

async function main() {
  const provider = new WsProvider(WS, 2500, {}, 600000);
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);
  const newBlock = () => send("dev_newBlock", [{ count: 1 }]);

  const chain = (await api.rpc.system.chain()).toString();
  console.log(`Connected to ${chain} @ #${(await api.rpc.chain.getHeader()).number.toNumber()}`);

  // --- the inner recovery call + the two whitelist wrappers --------------
  const inner = api.createType("Call", INNER);
  const innerHash = blake2AsHex(INNER);
  console.log(`Inner call hash: ${innerHash}  (${(INNER.length - 2) / 2} bytes)`);

  // who-targets + trap keys, decoded straight from the inner batch.
  // inner = utility.batchAll(Vec<Call>); inner.args[0] is the Vec<Call>.
  const whos = [];
  const trapKeys = [];
  for (const c of inner.args[0]) {
    if (c.section === "currencies" && c.method === "updateBalance") {
      whos.push(c.args[0].toString());
    } else if (c.section === "system" && c.method === "killStorage") {
      for (const k of c.args[0]) trapKeys.push(k.toHex());
    }
  }
  console.log("Beneficiaries:", whos);
  console.log("Trap keys:", trapKeys.length);

  const whitelistTx = api.tx.whitelist.whitelistCall(innerHash);
  const dispatchTx = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(inner);

  // --- generic preimage+scheduler injector with a chosen origin ----------
  async function enact(callHex, origin, label) {
    const hash = blake2AsHex(callHex);
    const len = (callHex.length - 2) / 2;
    const body = hexToU8a(callHex);
    const pKey = api.query.preimage.preimageFor.key([hash, len]);
    await send("dev_setStorage", [[[pKey, u8aToHex(u8aConcat(compactToU8a(body.length), body))]]]);
    const statusName = api.query.preimage.requestStatusFor ? "RequestStatusFor" : "StatusFor";
    await send("dev_setStorage", [{ Preimage: { [statusName]: [[[hash], { Requested: { maybeTicket: null, count: 1, maybeLen: len } }]] } }]);
    const head = (await api.rpc.chain.getHeader()).number.toNumber();
    const target = head + 1;
    await send("dev_setStorage", [{ Scheduler: { Agenda: [[[target], [{ maybeId: null, priority: 0, call: { Lookup: { hash_: hash, len } }, maybePeriodic: null, origin }]]] } }]);
    await newBlock();
    const bh = (await api.rpc.chain.getBlockHash(target)).toHex();
    const evs = await (await api.at(bh)).query.system.events();
    console.log(`\n-- ${label} @#${target} (origin ${JSON.stringify(origin)}) --`);
    let ok = true;
    for (const { event } of evs) {
      const k = `${event.section}.${event.method}`;
      if (k === "system.ExtrinsicSuccess") continue;
      if (/Failed|Unavailable|Overweight|NotWhitelisted|BadOrigin|Dispatched|Whitelisted|Deposited|BalanceSet|killed|Killed/i.test(k))
        console.log(`   ${k} ${JSON.stringify(event.data.toJSON())}`);
      if (/Failed|Unavailable|Overweight/i.test(event.method)) ok = false;
    }
    return ok;
  }

  // Optionally seed the trap keys. The public RPC forks ~123k blocks behind the
  // trapping blocks (#12.638M), so on this height the AssetTraps entries don't
  // exist yet and killStorage would be a no-op. SEED_TRAPS=1 writes a placeholder
  // u32 count at each key so the clearing is actually demonstrated.
  if (process.env.SEED_TRAPS === "1") {
    for (const k of trapKeys) await send("dev_setStorage", [[[k, "0x01000000"]]]);
    console.log("(seeded 3 trap keys with placeholder AssetTraps count=1)");
  }

  // --- balances + trap state BEFORE -------------------------------------
  const balOf = async (who) => (await api.query.tokens.accounts(who, ASSET)).free.toString();
  const issuanceBefore = (await api.query.tokens.totalIssuance(ASSET)).toString();
  const before = [];
  for (const w of whos) before.push(await balOf(w));
  const trapsBefore = [];
  for (const k of trapKeys) trapsBefore.push((await api.rpc.state.getStorage(k)).isSome);
  console.log("\nBEFORE  apyUSD balances:", before);
  console.log("BEFORE  trap keys present:", trapsBefore);
  console.log("BEFORE  asset-46 issuance:", issuanceBefore);

  // --- step 1: whitelist the call (WhitelistOrigin = Root) ---------------
  await enact(whitelistTx.method.toHex(), { system: "Root" }, "whitelist.whitelistCall");
  const isWhitelisted = (await api.query.whitelist.whitelistedCall(innerHash)).isSome;
  console.log(`   => call whitelisted on-chain: ${isWhitelisted}`);

  // --- step 2: dispatch as the WhitelistedCaller track origin ------------
  await enact(dispatchTx.method.toHex(), { Origins: "WhitelistedCaller" }, "whitelist.dispatchWhitelistedCallWithPreimage");

  // --- balances + trap state AFTER --------------------------------------
  const after = [];
  for (const w of whos) after.push(await balOf(w));
  const trapsAfter = [];
  for (const k of trapKeys) trapsAfter.push((await api.rpc.state.getStorage(k)).isSome);
  const issuanceAfter = (await api.query.tokens.totalIssuance(ASSET)).toString();

  console.log("\n=== RESULT (whitelisted enactment) ===");
  for (let i = 0; i < whos.length; i++) {
    const d = (BigInt(after[i]) - BigInt(before[i]));
    console.log(`  ${whos[i]}`);
    console.log(`     apyUSD ${before[i]} -> ${after[i]}  (+${(Number(d) / 1e18).toFixed(2)})`);
  }
  console.log("  trap keys present after:", trapsAfter, "(expect all false)");
  console.log(`  asset-46 issuance ${issuanceBefore} -> ${issuanceAfter}  (+${(Number(BigInt(issuanceAfter) - BigInt(issuanceBefore)) / 1e18).toFixed(2)})`);
  const minted = whos.every((_, i) => BigInt(after[i]) > BigInt(before[i]));
  const cleared = trapsAfter.every((x) => x === false);
  console.log(`\n  MINTED to all beneficiaries : ${minted}`);
  console.log(`  ALL TRAPS CLEARED           : ${cleared}`);
  console.log(`  WHITELISTED PATH SUCCEEDED  : ${minted && cleared}`);

  await api.disconnect();
}
main().catch((e) => { console.error("FATAL", e); process.exit(1); });
