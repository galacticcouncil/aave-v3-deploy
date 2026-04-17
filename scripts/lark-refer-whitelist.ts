// Full-path whitelist via OpenGov: Alice submits a whitelisted_caller referendum
// that dispatches evmAccounts.addContractDeployer via Root origin, then votes it through.
//
// Pipeline:
//   1. Note preimage for: whitelist.dispatchWhitelistedCall(innerHash, len, weight)
//      (The inner call `evmAccounts.addContractDeployer(EVM_DEPLOYER)` was already
//       whitelisted via TC in the prior step.)
//   2. referenda.submit on track 1 (whitelisted_caller) with this preimage
//   3. referenda.placeDecisionDeposit
//   4. convictionVoting.vote — aye with Locked6x (6x conviction)
//   5. Poll until referendum is Approved, then confirm deployer is whitelisted
//
// On lark with isTestnet=true, tracks have 1-block prepare/confirm/enactment, so this
// completes in ~5 blocks (~30s) given Alice has ~70% of issuance.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex, BN } from "@polkadot/util";
import type { SubmittableExtrinsic } from "@polkadot/api/types";

const LARK_WS = "wss://1.lark.hydration.cloud";
const EVM_DEPLOYER = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";
const TRACK_WHITELISTED_CALLER = 1;

function waitBlocks(api: ApiPromise, n: number): Promise<void> {
  return new Promise((resolve) => {
    let count = 0;
    api.rpc.chain.subscribeNewHeads((hdr) => {
      count++;
      if (count >= n) resolve();
    });
  });
}

async function signAndWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
          }
          return reject(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
          }
        }
        console.log(`  OK`);
        resolve(events as any[]);
      }
    }).catch(reject);
  });
}

async function main() {
  const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  console.log(`Alice: ${alice.address}`);

  // Check current state
  const dep: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (dep.isSome) {
    console.log(`✓ ${EVM_DEPLOYER} already whitelisted`);
    await api.disconnect();
    return;
  }

  // Inner call — already whitelisted via TC (no-op if so)
  const innerCall = api.tx.evmAccounts.addContractDeployer(EVM_DEPLOYER);
  const innerHash = innerCall.method.hash.toHex();
  const innerLen = innerCall.method.encodedLength;
  const innerInfo = await innerCall.paymentInfo(alice);
  const innerWeight = innerInfo.weight as any;

  const wlEntry: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wlEntry.isSome) {
    console.log(`Inner call not yet whitelisted - running TC propose first`);
    const whitelistCall = api.tx.whitelist.whitelistCall(innerHash);
    const wlLen = whitelistCall.method.encodedLength;
    const propose = api.tx.technicalCommittee.propose(1, whitelistCall, wlLen);
    await signAndWait(propose, alice, api, "TC propose(whitelist.whitelistCall)");
  } else {
    console.log(`Inner call already whitelisted in pallet`);
  }

  // Build the referendum's target call: whitelist.dispatchWhitelistedCall(hash, len, weight)
  const dispatchCall = api.tx.whitelist.dispatchWhitelistedCall(
    innerHash,
    innerLen,
    { refTime: innerWeight.refTime, proofSize: innerWeight.proofSize }
  );
  const dispatchEncoded = dispatchCall.method.toHex();
  const dispatchHash = dispatchCall.method.hash.toHex();
  const dispatchLen = dispatchCall.method.encodedLength;
  console.log(`\nRef target call hash: ${dispatchHash}`);
  console.log(`Ref target call length: ${dispatchLen}`);

  // Step 1: Note preimage (if not already noted)
  const pre: any = await api.query.preimage.statusFor(dispatchHash);
  if (!pre.isSome) {
    const notePreimage = api.tx.preimage.notePreimage(dispatchEncoded);
    await signAndWait(notePreimage, alice, api, "preimage.notePreimage");
  } else {
    console.log(`Preimage already noted`);
  }

  // Step 2: Submit referendum on track 1
  const proposalOrigin = { Origins: "WhitelistedCaller" };
  const proposal = { Lookup: { hash: dispatchHash, len: dispatchLen } };
  const enactmentMoment = { After: 1 };

  // Need to capture referendum index from event
  const submitTx = api.tx.referenda.submit(proposalOrigin, proposal, enactmentMoment);
  const events = await signAndWait(submitTx, alice, api, "referenda.submit");

  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      console.log(`  Referendum index: ${refIndex}`);
      break;
    }
  }
  if (refIndex == null) throw new Error("Could not find referendum index");

  // Step 3: Place decision deposit (50,000 HDX on testnet track 1)
  const placeDeposit = api.tx.referenda.placeDecisionDeposit(refIndex);
  await signAndWait(placeDeposit, alice, api, "referenda.placeDecisionDeposit");

  // Step 4: Vote aye with conviction 6x (Locked6x), full balance
  const balance: any = await api.query.system.account(alice.address);
  const voteBalance = balance.data.free.toBigInt() - BigInt(1_000_000) * BigInt(10 ** 12); // leave 1M HDX for gas/fees
  const voteTx = api.tx.convictionVoting.vote(refIndex, {
    Standard: {
      vote: { aye: true, conviction: "Locked6x" },
      balance: voteBalance.toString(),
    },
  });
  await signAndWait(voteTx, alice, api, `convictionVoting.vote (aye, 6x, ${voteBalance} raw)`);

  // Step 5: Poll for Approved status
  console.log(`\nPolling referendum #${refIndex}...`);
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!ref.isSome) {
      console.log(`  [${i}] no info`);
      continue;
    }
    const info = ref.unwrap();
    const t = info.type;
    console.log(`  [${i}] status: ${t}`);
    if (info.isOngoing) {
      const o = info.asOngoing;
      console.log(`        track=${o.track}, tally=${o.tally.toString()}`);
      if (!o.deciding.isNone) {
        const d = o.deciding.unwrap();
        console.log(`        deciding: since=${d.since}, confirming=${d.confirming}`);
      }
    }
    if (info.isApproved) {
      console.log(`  ✓ Referendum ${refIndex} Approved in block ${info.asApproved[0]}`);
      break;
    }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
      throw new Error(`Referendum ${refIndex} ${t} — cannot proceed`);
    }
  }

  // Wait a few blocks for enactment
  console.log(`\nWaiting for enactment...`);
  await new Promise((r) => setTimeout(r, 12000));

  // Verify
  const finalCheck: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (finalCheck.isSome) {
    console.log(`\n✓✓✓ ${EVM_DEPLOYER} IS NOW WHITELISTED`);
  } else {
    console.log(`\n⚠ Not yet whitelisted — check scheduler or wait more`);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
