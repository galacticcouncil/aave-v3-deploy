#!/usr/bin/env node
// fund the propeller rebalancer bot via governance (root referendum on lark2).
//
// lark2 has no sudo, so PRIME (asset 43) can't be minted directly. instead we
// pass a Root-track referendum that calls currencies.updateBalance to credit the
// bot account with a large PRIME + HOLLAR stock. Alice is the sole TC member and
// holds ~4B HDX, which instantly confirms the Root track.
//
// flow (mirrors submit-hdcl-proposal.ts, minus the hardhat-built payload):
//   1. preimage.notePreimage(batchAll)
//   2. referenda.submit(Root, Lookup{hash,len}, After:1)
//   3. placeDecisionDeposit + convictionVoting.vote(aye, 6x, 4B HDX)
//   4. poll referendumInfoFor until Approved, wait for enactment
//   5. verify bot balances
//
// usage:
//   node scripts/propeller-fund-bot.mjs <botAddr>            # dry-run (prints call, no broadcast)
//   node scripts/propeller-fund-bot.mjs <botAddr> --live     # submit + vote + enact
//   PROPOSAL_WS=ws://127.0.0.1:8011 ... --live               # against chopsticks fork

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const BOT = process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : process.env.BOT_ADDR;

const PRIME = 43, HOLLAR = 222;
const PRIME_AMT = (process.env.PRIME_AMT ? BigInt(process.env.PRIME_AMT) : 1_000_000_000n) * 10n ** 6n; // 1e9 PRIME, 6dp
// HOLLAR (222) is an Erc20-type asset — balance lives in the EVM contract and
// is NOT mintable via currencies/tokens (currencies.NotSupported). it's minted
// by the HSM facilitator against collateral. so we only mint PRIME here; the bot
// obtains HOLLAR by swapping PRIME when it needs the other direction. set
// HOLLAR_AMT>0 only if a future runtime makes 222 mintable.
const HOLLAR_AMT = (process.env.HOLLAR_AMT ? BigInt(process.env.HOLLAR_AMT) : 0n) * 10n ** 18n;
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
      for (const { event } of events) {
        if (event.section === "system" && event.method === "ExtrinsicFailed") { unsub?.(); return reject(new Error("ExtrinsicFailed")); }
      }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  if (!BOT) { console.error("usage: propeller-fund-bot.mjs <botAddr> [--live]"); process.exit(1); }
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const calls = [api.tx.currencies.updateBalance(BOT, PRIME, PRIME_AMT.toString())];
  if (HOLLAR_AMT > 0n) calls.push(api.tx.currencies.updateBalance(BOT, HOLLAR, HOLLAR_AMT.toString()));
  const proposal = calls.length === 1 ? calls[0] : api.tx.utility.batchAll(calls);
  const proposalHex = proposal.method.toHex();
  const proposalHash = proposal.method.hash.toHex();
  const proposalLen = proposal.method.encodedLength;

  console.log(`ws=${WS}  bot=${BOT}`);
  console.log(`mint: ${PRIME_AMT / 10n ** 6n} PRIME${HOLLAR_AMT > 0n ? ` + ${HOLLAR_AMT / 10n ** 18n} HOLLAR` : ""}`);
  console.log(`proposal hash=${proposalHash} len=${proposalLen}`);

  const before43 = (await api.query.tokens.accounts(BOT, PRIME)).free.toBigInt();
  const before222 = (await api.query.tokens.accounts(BOT, HOLLAR)).free.toBigInt();
  console.log(`bot before: PRIME=${before43 / 10n ** 6n}  HOLLAR=${before222 / 10n ** 18n}`);

  if (!LIVE) {
    console.log(`\nDRY-RUN — not broadcasting. call: ${proposalHex.slice(0, 30)}...`);
    await api.disconnect(); return;
  }

  const aliceAcct = await api.query.system.account(alice.address);
  console.log(`Alice free=${aliceAcct.data.free.toBigInt() / HDX} HDX`);

  try {
    await signAndWait(api.tx.preimage.notePreimage(proposalHex), alice, api, "notePreimage");
  } catch (e) {
    if (!/AlreadyNoted/i.test(e.message)) throw e;
    console.log("  preimage already noted — continuing");
  }

  const ev = await signAndWait(
    api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash: proposalHash, len: proposalLen } }, { After: 1 }),
    alice, api, "referenda.submit(Root)"
  );
  let refIndex = null;
  for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") refIndex = event.data[0].toNumber();
  if (refIndex == null) throw new Error("no refIndex");
  console.log(`Referendum #${refIndex}`);

  await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api, "placeDecisionDeposit");
  const voteBalance = (4_000_000_000n * HDX).toString();
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance } }),
    alice, api, "convictionVoting.vote"
  );

  console.log("\npolling referendum...");
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const ref = await api.query.referenda.referendumInfoFor(refIndex);
    if (!ref.isSome) continue;
    const info = ref.unwrap();
    console.log(`[${i}] ${info.type}`);
    if (info.isApproved) break;
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error(`ref ${info.type}`);
  }
  console.log("waiting 24s for enactment...");
  await new Promise((r) => setTimeout(r, 24000));

  const after43 = (await api.query.tokens.accounts(BOT, PRIME)).free.toBigInt();
  const after222 = (await api.query.tokens.accounts(BOT, HOLLAR)).free.toBigInt();
  console.log(`\nbot after: PRIME=${after43 / 10n ** 6n}  HOLLAR=${after222 / 10n ** 18n}`);
  const ok = after43 > before43 && (HOLLAR_AMT === 0n || after222 > before222);
  console.log(ok ? "FUNDED ✓" : "NOT funded — check enactment / referendum outcome");
  await api.disconnect();
}

main().catch((e) => { console.error(e); process.exit(1); });
