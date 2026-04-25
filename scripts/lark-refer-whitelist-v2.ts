// Corrected flow: ALSO note the inner preimage so dispatchWhitelistedCall can load it.
// The first attempt failed with whitelist.UnavailablePreImage.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { BN } from "@polkadot/util";
import type { SubmittableExtrinsic } from "@polkadot/api/types";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const EVM_DEPLOYER = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";

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

  const dep: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (dep.isSome) {
    console.log(`✓ Already whitelisted`);
    await api.disconnect();
    return;
  }

  // Inner call
  const innerCall = api.tx.evmAccounts.addContractDeployer(EVM_DEPLOYER);
  const innerHash = innerCall.method.hash.toHex();
  const innerEncoded = innerCall.method.toHex();
  const innerLen = innerCall.method.encodedLength;
  const innerInfo = await innerCall.paymentInfo(alice);
  const innerWeight = innerInfo.weight as any;

  // Step 1: Note the INNER preimage (this was missing before)
  const innerPre: any = await api.query.preimage.requestStatusFor
    ? await api.query.preimage.requestStatusFor(innerHash)
    : await api.query.preimage.statusFor(innerHash);
  if (!innerPre.isSome) {
    await signAndWait(api.tx.preimage.notePreimage(innerEncoded), alice, api, "preimage.notePreimage(innerCall)");
  } else {
    console.log(`Inner preimage already noted`);
  }

  // Step 2: Ensure inner call is whitelisted in pallet-whitelist
  const wlEntry: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wlEntry.isSome) {
    const whitelistCall = api.tx.whitelist.whitelistCall(innerHash);
    const wlLen = whitelistCall.method.encodedLength;
    await signAndWait(
      api.tx.technicalCommittee.propose(1, whitelistCall, wlLen),
      alice, api, "TC propose(whitelist.whitelistCall)"
    );
  } else {
    console.log(`Inner call already whitelisted in pallet`);
  }

  // Step 3: Build dispatch call
  const dispatchCall = api.tx.whitelist.dispatchWhitelistedCall(
    innerHash,
    innerLen,
    { refTime: innerWeight.refTime, proofSize: innerWeight.proofSize }
  );
  const dispatchEncoded = dispatchCall.method.toHex();
  const dispatchHash = dispatchCall.method.hash.toHex();
  const dispatchLen = dispatchCall.method.encodedLength;

  // Note the dispatch preimage (if not already)
  const dispatchPre: any = await api.query.preimage.requestStatusFor
    ? await api.query.preimage.requestStatusFor(dispatchHash)
    : await api.query.preimage.statusFor(dispatchHash);
  if (!dispatchPre.isSome) {
    await signAndWait(api.tx.preimage.notePreimage(dispatchEncoded), alice, api, "preimage.notePreimage(dispatch)");
  } else {
    console.log(`Dispatch preimage already noted`);
  }

  // Step 4: Submit referendum on track 1
  const proposalOrigin = { Origins: "WhitelistedCaller" };
  const proposal = { Lookup: { hash: dispatchHash, len: dispatchLen } };
  const enactmentMoment = { After: 1 };

  const events = await signAndWait(
    api.tx.referenda.submit(proposalOrigin, proposal, enactmentMoment),
    alice, api, "referenda.submit"
  );

  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no referendum index");
  console.log(`Referendum: ${refIndex}`);

  // Step 5: Decision deposit + vote
  await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api, "placeDecisionDeposit");

  const balance: any = await api.query.system.account(alice.address);
  const voteBalance = balance.data.free.toBigInt() - BigInt(1_000_000) * BigInt(10 ** 12);
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance.toString() },
    }),
    alice, api, `vote(aye, 6x)`
  );

  // Step 6: Poll
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!ref.isSome) { console.log(`[${i}] no info`); continue; }
    const info = ref.unwrap();
    console.log(`[${i}] ${info.type}`);
    if (info.isApproved) break;
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
      throw new Error(`Ref ${refIndex} ${info.type}`);
    }
  }

  // Wait for enactment
  console.log("\nWaiting 12s for enactment...");
  await new Promise((r) => setTimeout(r, 12000));

  const final: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (final.isSome) {
    console.log(`\n✓✓✓ ${EVM_DEPLOYER} WHITELISTED`);
  } else {
    // Print all whitelisted to debug
    const all = await api.query.evmAccounts.contractDeployer.entries();
    console.log("\n⚠ Not whitelisted. All entries:");
    for (const [k] of all) console.log(`  ${k.args[0].toString()}`);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
