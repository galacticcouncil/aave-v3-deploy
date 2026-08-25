// One-shot Root ref on 0.lark, single batchAll:
//   1. stableswap.updateAmplification(10055, 100 → 50) ramping ~15 min out
//   2. temp GHO facilitator for the Treasury (bucket = exact mint, self-sealing)
//   3. Treasury mints HOLLAR → zaps to BIL → buys HOLLAR out of the pool
//      until exactly 100K HOLLAR remains (exit-flow simulation for the
//      amp-50 discount curve).
//
// The buy executes at enactment — before the amp ramp starts — so sizing is
// computed at amp 100. Ramp start needs start_block >= current at execution
// (Error::PastBlock), hence the +150 cushion over the ~10-block enactment lag.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady, blake2AsU8a, decodeAddress } from "@polkadot/util-crypto";
import { u8aToHex, hexToU8a } from "@polkadot/util";
import { utils } from "ethers";
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const math = require("/home/mrq/git/hydration-ui/node_modules/@galacticcouncil/math-stableswap/build/index.cjs");

const RPC = process.env.RPC || "wss://node0.lark.hydration.cloud";
const ETH_RPC = "https://node0.lark.hydration.cloud";

const POOL_ID = 10055;
const BIL = 55;
const HOLLAR_ID = 222;
const NEW_AMP = 50;
const TARGET_HOLLAR = 100_000n * 10n ** 18n;

const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const BIL_ATOKEN = "0xCc7Dc2433073ed4cf1daFd1A1b9c32e193cce5ce";
const VAULT = "0x7a1FFcF0949C6cf85d16BA04221D650Db0dE41A5";
const ZAP = "0xFF14a4Bf1Fe038D23b68d738B81cF900FD6E9D8B";
const AAVE_MANAGER = "0xaa7e0000000000000000000000000000000aa7e0";
const TREASURY = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

const E18 = 10n ** 18n;
const fmt = (x) => (Number(x) / 1e18).toLocaleString("en", { maximumFractionDigits: 2 });

await cryptoWaitReady();
const api = await ApiPromise.create({ provider: new WsProvider(RPC), noInitWarn: true });
console.log(`Chain: ${(await api.rpc.system.chain()).toString()}`);

const keyring = new Keyring({ type: "sr25519" });
const alice = keyring.addFromUri("//Alice");

const treasuryEvm = u8aToHex(decodeAddress(TREASURY).slice(0, 20));
// stableswap pool account = blake2_256("sts" ++ pool_id LE), EVM = first 20 bytes
const poolAccount = blake2AsU8a(hexToU8a("0x737473" + "47270000"), 256);
const poolEvm = u8aToHex(poolAccount.slice(0, 20));

// ---- Live state ----
const ethCall = async (to, data) => {
  const r = await fetch(ETH_RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  }).then((x) => x.json());
  if (r.error) throw new Error(JSON.stringify(r.error));
  return BigInt(r.result);
};
const balOf = (token, addr) => ethCall(token, "0x70a08231" + addr.slice(2).padStart(64, "0"));

const readPool = async () => ({
  bil: await balOf(BIL_ATOKEN, poolEvm),
  hollar: await balOf(HOLLAR, poolEvm),
});

const nowBlock = (await api.rpc.chain.getHeader()).number.toNumber();
const before = await readPool();
const rate = await ethCall(VAULT, "0x3ba0b9a9"); // exchangeRate()
console.log(`block ${nowBlock} | pool: ${fmt(before.bil)} BIL / ${fmt(before.hollar)} HOLLAR | rate ${Number(rate) / 1e18}`);

const pool = (await api.query.stableswap.pools(POOL_ID)).unwrap();
const curAmp = pool.finalAmplification.toNumber();
if (curAmp !== 100) console.log(`WARN: current amp is ${curAmp}, expected 100`);

// ---- Sizing (at amp 100 — the buy runs before the ramp starts) ----
const hollarOut = before.hollar - TARGET_HOLLAR;
if (hollarOut <= 0n) throw new Error("pool already at/below 100K HOLLAR");
const reserves = JSON.stringify([
  { asset_id: BIL, amount: before.bil.toString(), decimals: 18 },
  { asset_id: HOLLAR_ID, amount: before.hollar.toString(), decimals: 18 },
]);
// peg jumps to the oracle target on the trade (updatedAt is thousands of blocks old)
const pegs = JSON.stringify([[rate.toString(), E18.toString()], ["1", "1"]]);
const bilNeeded = BigInt(math.calculate_in_given_out(reserves, BIL, HOLLAR_ID, hollarOut.toString(), String(curAmp), "0.001", pegs));
const mintAmount = (bilNeeded * rate / E18) * 103n / 100n; // 3% drift buffer
const maxSell = mintAmount * E18 / rate + 900n * E18; // everything the zap mints + existing dust
console.log(`buy ${fmt(hollarOut)} HOLLAR out | ~${fmt(bilNeeded)} BIL in | mint ${fmt(mintAmount)} HOLLAR`);

// ---- Build calls ----
const evmCall = (from, to, data, gasLimit) =>
  api.tx.evm.call(from, to, data, "0", gasLimit, "600000000", undefined, undefined, [], []);
const asAaveManager = (to, data, gasLimit) =>
  api.tx.dispatcher.dispatchAsAaveManager(evmCall(AAVE_MANAGER, to, data, gasLimit));
const asTreasury = (tx) => api.tx.utility.dispatchAs({ system: { signed: TREASURY } }, tx);

const ghoIface = new utils.Interface([
  "function addFacilitator(address facilitatorAddress, string facilitatorLabel, uint128 bucketCapacity)",
  "function mint(address account, uint256 amount)",
  "function approve(address spender, uint256 value) returns (bool)",
]);
const zapIface = new utils.Interface(["function depositAndSupply(uint256 hollarAmount)"]);

const ampStart = nowBlock + 150;
const ampEnd = nowBlock + 200;

const calls = [
  // 1. amp 100 → 50, ramping over 50 blocks starting ~15 min out
  api.tx.stableswap.updateAmplification(POOL_ID, NEW_AMP, ampStart, ampEnd),
  // 2. temp facilitator: bucket = exact mint, so it seals itself after the mint
  asAaveManager(HOLLAR, ghoIface.encodeFunctionData("addFacilitator", [treasuryEvm, "bil-amp-test", mintAmount]), "300000"),
  // 3. Treasury mints its bucket
  asTreasury(evmCall(treasuryEvm, HOLLAR, ghoIface.encodeFunctionData("mint", [treasuryEvm, mintAmount]), "300000")),
  // 4-5. zap HOLLAR → BIL (same pattern as the bootstrap proposal)
  asTreasury(evmCall(treasuryEvm, HOLLAR, ghoIface.encodeFunctionData("approve", [ZAP, mintAmount]), "200000")),
  asTreasury(evmCall(treasuryEvm, ZAP, zapIface.encodeFunctionData("depositAndSupply", [mintAmount]), "5000000")),
  // 6. exact-out buy: drain the pool to precisely 100K HOLLAR
  asTreasury(api.tx.stableswap.buy(POOL_ID, HOLLAR_ID, BIL, hollarOut, maxSell)),
];

const batchAll = api.tx.utility.batchAll(calls);
const proposalHex = batchAll.method.toHex();
const proposalHash = batchAll.method.hash.toHex();
const proposalLen = batchAll.method.encodedLength;
console.log(`\nbatchAll (${proposalLen} bytes), hash ${proposalHash}`);

// ---- Submit + self-enact as Alice ----
const signAndWait = (tx, label) =>
  new Promise((resolve, reject) => {
    console.log(`--- ${label} ---`);
    let unsub;
    tx.signAndSend(alice, ({ status, dispatchError, events }) => {
      if (status.isInBlock || status.isFinalized) {
        if (dispatchError) {
          const msg = dispatchError.isModule
            ? (() => { const d = api.registry.findMetaError(dispatchError.asModule); return `${d.section}.${d.name}`; })()
            : dispatchError.toString();
          if (unsub) unsub();
          reject(new Error(msg));
          return;
        }
        if (unsub) unsub();
        resolve(events);
      }
    }).then((u) => { unsub = u; }).catch(reject);
  });

try {
  await signAndWait(api.tx.preimage.notePreimage(proposalHex), "preimage.notePreimage");
} catch (e) {
  if (!/AlreadyNoted/i.test(e.message)) throw e;
  console.log("  (already noted)");
}

const submitEvents = await signAndWait(
  api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash: proposalHash, len: proposalLen } }, { After: 1 }),
  "referenda.submit(Root)",
);
let refIndex = null;
for (const { event } of submitEvents)
  if (event.section === "referenda" && event.method === "Submitted") refIndex = event.data[0].toNumber();
if (refIndex == null) throw new Error("no refIndex");
console.log(`Referendum ${refIndex}`);

await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), "placeDecisionDeposit");
await signAndWait(
  api.tx.convictionVoting.vote(refIndex, {
    Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * 10n ** 12n).toString() },
  }),
  "convictionVoting.vote",
);

console.log("\nPolling for approval...");
for (let i = 0; i < 90; i++) {
  await new Promise((r) => setTimeout(r, 3000));
  const ref = await api.query.referenda.referendumInfoFor(refIndex);
  if (!ref.isSome) continue;
  const info = ref.unwrap();
  if (i % 5 === 0 || !info.isOngoing) console.log(`  [${i}] ${info.type}`);
  if (info.isApproved) break;
  if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled)
    throw new Error(`Ref ${refIndex} ${info.type}`);
}
console.log("Waiting 24s for enactment...");
await new Promise((r) => setTimeout(r, 24000));

// ---- Verify ----
const after = await readPool();
const poolAfter = (await api.query.stableswap.pools(POOL_ID)).unwrap();
const treasBil = await balOf(BIL_ATOKEN, treasuryEvm);
const treasHollar = await balOf(HOLLAR, treasuryEvm);
console.log(`\n=== Post-state ===`);
console.log(`pool: ${fmt(after.bil)} BIL / ${fmt(after.hollar)} HOLLAR (target 100,000)`);
console.log(`amp:  initial ${poolAfter.initialAmplification} → final ${poolAfter.finalAmplification} over blocks ${poolAfter.initialBlock}-${poolAfter.finalBlock}`);
console.log(`treasury leftovers: ${fmt(treasBil)} BIL, ${fmt(treasHollar)} HOLLAR`);
const ok = after.hollar === TARGET_HOLLAR && poolAfter.finalAmplification.toNumber() === NEW_AMP;
console.log(ok ? "✓ SUCCESS" : "✗ CHECK STATE");
await api.disconnect();
process.exit(ok ? 0 : 1);
