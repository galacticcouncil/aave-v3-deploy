#!/usr/bin/env node
// fund the Propeller deposit on real lark2 via one Root referendum:
//   - mint ETH (asset 34, Token-type) to the depositor's truncated EVM account
//     (so the 0x..0022 ERC20 precompile sees it for approve/deposit)
//   - mint HDX (asset 0) to the SubLoop's DCA-owner account (the 0x0401 schedule
//     is owned by the subLoop's unbound EVM acct; it needs native HDX for the
//     schedule ED/fee)
//
// the depositor is the forge deployer 0x2222..b (unbound → balances read from
// trunc = "ETH\0"++addr++8x0). after this, drive approve+deposit with cast.
//
// usage: node scripts/propeller-deposit-fund-lark.mjs [--live]

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");

const SUBLOOP = "f23f4bafb4560dfb3234ad7f441da6260b4218e8";
const trunc = (a) => "0x45544800" + a + "0000000000000000";
// depositor = //Alice's NORMAL substrate account (5Grwva...); her EVM address
// 0xd435.. maps here (first 20 bytes of pubkey), so minted ETH lands free and
// is visible via the ERC20 precompile — unlike an unbound trunc account where
// the deposit-limiter reserves it.
const DEPOSITOR_ACCT = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const SUBLOOP_OWNER = trunc(SUBLOOP);

const ETH_ASSET = 34, HDX_ASSET = 0;
const ETH_AMT = (process.env.ETH_AMT ? BigInt(process.env.ETH_AMT) : 60n) * 10n ** 18n;   // 60 ETH
const HDX_AMT = (process.env.HDX_AMT ? BigInt(process.env.HDX_AMT) : 100000n) * 10n ** 12n; // 100k HDX
const HDX = 10n ** 12n;

async function signAndWait(tx, signer, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(signer.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(signer, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() };
        unsub?.(); return reject(new Error(`${e.section}.${e.name}`));
      }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const batch = api.tx.utility.batchAll([
    api.tx.currencies.updateBalance(DEPOSITOR_ACCT, ETH_ASSET, ETH_AMT.toString()),
    api.tx.currencies.updateBalance(SUBLOOP_OWNER, HDX_ASSET, HDX_AMT.toString()),
  ]);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  console.log(`ws=${WS} live=${LIVE}`);
  console.log(`mint ${ETH_AMT / 10n ** 18n} ETH -> ${DEPOSITOR_ACCT}`);
  console.log(`mint ${HDX_AMT / HDX} HDX -> ${SUBLOOP_OWNER} (DCA owner)`);

  const beforeEth = (await api.query.tokens.accounts(DEPOSITOR_ACCT, ETH_ASSET)).free.toBigInt();
  console.log(`depositor ETH before: ${beforeEth}`);

  if (!LIVE) { console.log("\nDRY-RUN"); await api.disconnect(); return; }

  try { await signAndWait(api.tx.preimage.notePreimage(hex), alice, api, "notePreimage"); }
  catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; console.log("  already noted"); }

  const ev = await signAndWait(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
  let ref = null;
  for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log(`  referendum #${ref}`);
  await signAndWait(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "deposit");
  await signAndWait(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");

  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) { console.log(`  [${i}] Approved`); break; }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error(`ref ${info.type}`);
  }
  await new Promise((r) => setTimeout(r, 18000));
  const afterEth = (await api.query.tokens.accounts(DEPOSITOR_ACCT, ETH_ASSET)).free.toBigInt();
  const subHdx = (await api.query.system.account(SUBLOOP_OWNER)).data.free.toBigInt();
  console.log(`\ndepositor ETH after: ${afterEth} (${afterEth / 10n ** 18n} ETH)`);
  console.log(`subLoop DCA owner HDX: ${subHdx / HDX}`);
  console.log(afterEth > beforeEth ? "FUNDED ✓" : "NOT funded");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
