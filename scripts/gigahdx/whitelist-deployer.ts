// Whitelist our EVM deployer 0x222222...9531 on lark 1 using Alice (sole TechnicalCommittee member).
//
// Flow (Polkadot Whitelist pallet pattern):
//   1. Build inner call: evmAccounts.addContractDeployer(0x222222...9531)  [requires Root]
//   2. Alice (TC member) proposes + executes: technicalCommittee.propose(whitelist.whitelistCall(inner.hash))
//      With 1-member committee, propose executes immediately at threshold 1.
//   3. Anyone calls whitelist.dispatchWhitelistedCall(innerHash, innerEncoded, weight) to run it as Root.
//
// Ref: pallet-whitelist docs - https://paritytech.github.io/polkadot-sdk/master/pallet_whitelist/
// Ref: TechnicalCommittee origin type mapped to WhitelistOrigin for whitelist_call

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex, BN } from "@polkadot/util";
import type { SubmittableExtrinsic } from "@polkadot/api/types";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const EVM_DEPLOYER = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";

async function signAndSendWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<void> {
  console.log(`\n--- Submitting ${label} ---`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }) => {
      if (status.isInBlock) {
        console.log(`  in block: ${status.asInBlock.toHex()}`);
      }
      if (status.isFinalized) {
        console.log(`  finalized: ${status.asFinalized.toHex()}`);
        if (dispatchError) {
          if (dispatchError.isModule) {
            const decoded = api.registry.findMetaError(dispatchError.asModule);
            console.error(`  ERROR: ${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`);
            return reject(new Error(`${decoded.section}.${decoded.name}`));
          }
          console.error(`  ERROR: ${dispatchError.toString()}`);
          return reject(new Error(dispatchError.toString()));
        }
        // Scan events for failures
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            console.error(`  ExtrinsicFailed: ${event.data.toString()}`);
            return reject(new Error("ExtrinsicFailed"));
          }
        }
        console.log(`  OK`);
        resolve();
      }
    }).catch(reject);
  });
}

async function main() {
  const provider = new WsProvider(LARK_WS);
  const api = await ApiPromise.create({ provider });

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  console.log(`Alice: ${alice.address}`);

  // Check isTestnet
  try {
    const isTestnet: any = await api.query.parameters.isTestnet();
    console.log(`Parameters.isTestnet: ${isTestnet.toString()}`);
  } catch (e) {}

  // Build the inner call we want to execute with Root origin
  const innerCall = api.tx.evmAccounts.addContractDeployer(EVM_DEPLOYER);
  const innerHash = innerCall.method.hash.toHex();
  const innerEncoded = innerCall.method.toHex();
  const innerLen = innerCall.method.encodedLength;
  console.log(`\nInner call: evmAccounts.addContractDeployer(${EVM_DEPLOYER})`);
  console.log(`  hash: ${innerHash}`);
  console.log(`  encoded length: ${innerLen}`);

  // Check if already whitelisted
  const dep: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (dep.isSome) {
    console.log("\n✓ Already whitelisted, nothing to do");
    await api.disconnect();
    return;
  }

  // Step 1: Check if the call is already whitelisted (via Whitelist pallet)
  const wlStorage: any = await api.query.whitelist.whitelistedCall(innerHash);
  const alreadyWhitelisted = wlStorage.isSome;
  console.log(`\nWhitelisted in Whitelist pallet: ${alreadyWhitelisted}`);

  if (!alreadyWhitelisted) {
    // TC member (Alice) proposes whitelist.whitelistCall(innerHash)
    // technicalCommittee.propose(threshold=1, whitelist.whitelistCall(hash), lengthBound)
    // With threshold=1 and Alice as sole member, it executes immediately.
    const whitelistCall = api.tx.whitelist.whitelistCall(innerHash);
    const wlLen = whitelistCall.method.encodedLength;
    const propose = api.tx.technicalCommittee.propose(1, whitelistCall, wlLen);

    await signAndSendWait(propose, alice, api, "TC propose(whitelist.whitelistCall)");

    // Verify
    const wlNow: any = await api.query.whitelist.whitelistedCall(innerHash);
    if (!wlNow.isSome) {
      throw new Error("Whitelist entry not present after propose — check TC origin mapping");
    }
    console.log("✓ Call is now whitelisted");
  }

  // Step 2: Dispatch the whitelisted call with Root origin
  // whitelist.dispatchWhitelistedCall(callHash, callWeightWitness, encodedCall) or
  // whitelist.dispatchWhitelistedCallWithPreimage(encodedCall)
  // The encoded call -> Root origin executes it
  const dispatchMethods = Object.keys(api.tx.whitelist || {});
  console.log(`\nWhitelist pallet methods: ${dispatchMethods.join(", ")}`);

  // Direct `dispatchWhitelistedCall*` from a signed account fails with BadOrigin
  // because Hydration's WhitelistOrigin only accepts WhitelistedCaller (a track-1
  // ref) or Root — not plain Signed. We try the direct path first to short-circuit
  // on a permissioned chain, then fall through to the referendum path below.
  if (api.tx.whitelist.dispatchWhitelistedCallWithPreimage) {
    try {
      const dispatch = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
      await signAndSendWait(dispatch, alice, api, "whitelist.dispatchWhitelistedCallWithPreimage (direct)");
      const postCheck: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
      if (postCheck.isSome) {
        console.log(`\n✓ ${EVM_DEPLOYER} whitelisted via direct dispatch`);
        await api.disconnect();
        return;
      }
    } catch (e: any) {
      if (!String(e.message).includes("BadOrigin")) throw e;
      console.log(`  (direct dispatch returned BadOrigin — falling through to referendum)`);
    }
  }

  // Fallback: submit a track-1 (whitelisted_caller) referendum that runs the
  // wrapper, which then dispatches the inner call with Root.
  const wrapper = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
  const wrapperHex = wrapper.method.toHex();
  const wrapperHash = wrapper.method.hash.toHex();
  const wrapperLen = wrapper.method.encodedLength;
  console.log(`\nFallback wrapper hash: ${wrapperHash} len: ${wrapperLen}`);

  const pre: any = await api.query.preimage.requestStatusFor(wrapperHash);
  const preOld: any = await api.query.preimage.statusFor(wrapperHash);
  if (!pre.isSome && !preOld.isSome) {
    await signAndSendWait(api.tx.preimage.notePreimage(wrapperHex), alice, api, "preimage.notePreimage(wrapper)");
  } else {
    console.log("wrapper preimage already noted");
  }

  let refIndex: number | null = null;
  await new Promise<void>((resolve, reject) => {
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: wrapperHash, len: wrapperLen } },
      { After: 1 }
    ).signAndSend(alice, ({ status, dispatchError, events }: any) => {
      if (status.isInBlock) console.log(`  ref submit in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (!status.isFinalized) return;
      if (dispatchError) {
        if (dispatchError.isModule) {
          const d = api.registry.findMetaError(dispatchError.asModule);
          return reject(new Error(`${d.section}.${d.name}`));
        }
        return reject(new Error(dispatchError.toString()));
      }
      for (const { event } of events) {
        if (event.section === "referenda" && event.method === "Submitted") {
          refIndex = (event.data[0] as any).toNumber();
        }
      }
      resolve();
    }).catch(reject);
  });
  if (refIndex == null) throw new Error("no Submitted event");
  console.log(`ref: ${refIndex}`);

  await signAndSendWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api, "placeDecisionDeposit");

  const bal: any = await api.query.system.account(alice.address);
  const free = bal.data.free.toBigInt();
  const MAX_VOTE = 4_000_000_000n * 10n ** 12n;
  const voteBalance = (free < MAX_VOTE ? free : MAX_VOTE).toString();
  console.log(`voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX at 6x`);
  await signAndSendWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote(aye, 6x)"
  );

  console.log(`\npolling ref ${refIndex}...`);
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!info.isSome) continue;
    const r = info.unwrap();
    if (r.isApproved) { console.log("  Approved"); break; }
    if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled) throw new Error(r.type);
    if (i % 3 === 0) console.log(`  [${i}] ${r.type}`);
  }
  await new Promise((r) => setTimeout(r, 15000));

  const postCheck: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  console.log(`\n${EVM_DEPLOYER} whitelisted (post): ${postCheck.isSome}`);
  if (!postCheck.isSome) throw new Error("whitelist did not enact");
  console.log("✓✓✓ deployer whitelisted via referendum");

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
