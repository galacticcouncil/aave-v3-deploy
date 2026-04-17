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

const LARK_WS = "wss://1.lark.hydration.cloud";
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

  let dispatch: SubmittableExtrinsic<"promise">;
  if (api.tx.whitelist.dispatchWhitelistedCallWithPreimage) {
    dispatch = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
  } else if (api.tx.whitelist.dispatchWhitelistedCall) {
    // Need weight for this variant
    const info = await innerCall.paymentInfo(alice);
    const weight = info.weight as any;
    dispatch = api.tx.whitelist.dispatchWhitelistedCall(
      innerHash,
      innerLen,
      { refTime: weight.refTime, proofSize: weight.proofSize }
    );
  } else {
    throw new Error("No dispatch method found on whitelist pallet");
  }

  await signAndSendWait(dispatch, alice, api, "whitelist.dispatchWhitelistedCall*");

  // Verify
  const postCheck: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  console.log(`\n✓ ${EVM_DEPLOYER} whitelisted (post): ${postCheck.isSome}`);

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
