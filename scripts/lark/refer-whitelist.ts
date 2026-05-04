// v3: Use dispatchWhitelistedCallWithPreimage which embeds the inner call directly.
// Also ensure inner preimage is actually noted (not just requested).

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import type { SubmittableExtrinsic } from "@polkadot/api/types";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const EVM_DEPLOYER = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";

async function signAndWait(tx: SubmittableExtrinsic<"promise">, signer: any, api: ApiPromise, label: string): Promise<any[]> {
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

  const check: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (check.isSome) {
    console.log("Already whitelisted");
    await api.disconnect();
    return;
  }

  // Inner call
  const innerCall = api.tx.evmAccounts.addContractDeployer(EVM_DEPLOYER);
  const innerHash = innerCall.method.hash.toHex();

  // Verify whitelist entry exists (it should from prior runs)
  const wl: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wl.isSome) {
    console.log("Whitelist entry missing — running TC propose");
    const whitelistCall = api.tx.whitelist.whitelistCall(innerHash);
    await signAndWait(
      api.tx.technicalCommittee.propose(1, whitelistCall, whitelistCall.method.encodedLength),
      alice, api, "TC propose"
    );
  } else {
    console.log(`✓ Whitelist entry exists: ${JSON.stringify(wl.toHuman())}`);
  }

  // Use dispatchWhitelistedCallWithPreimage — embeds the inner call inline.
  // This bypasses the separate preimage lookup.
  const dispatchCall = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
  const dispatchEncoded = dispatchCall.method.toHex();
  const dispatchHash = dispatchCall.method.hash.toHex();
  const dispatchLen = dispatchCall.method.encodedLength;
  console.log(`\nDispatch-with-preimage call hash: ${dispatchHash}, len: ${dispatchLen}`);

  // Note the outer preimage (the dispatch call itself)
  const outerStatus: any = await api.query.preimage.statusFor(dispatchHash);
  if (!outerStatus.isSome) {
    await signAndWait(api.tx.preimage.notePreimage(dispatchEncoded), alice, api, "preimage.notePreimage(dispatch)");
  } else {
    console.log("Outer preimage already noted");
  }

  // Submit referendum on track 1
  const events = await signAndWait(
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: dispatchHash, len: dispatchLen } },
      { After: 1 }
    ),
    alice, api, "referenda.submit"
  );

  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no refIndex");
  console.log(`Referendum: ${refIndex}`);

  await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api, "placeDecisionDeposit");

  const bal: any = await api.query.system.account(alice.address);
  const voteBalance = (bal.data.free.toBigInt() - BigInt(1_000_000) * BigInt(10 ** 12)).toString();
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice, api, "vote"
  );

  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!ref.isSome) continue;
    const info = ref.unwrap();
    console.log(`[${i}] ${info.type}`);
    if (info.isApproved) break;
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled)
      throw new Error(`Ref ${refIndex} ${info.type}`);
  }

  console.log("Waiting 18s for enactment...");
  await new Promise((r) => setTimeout(r, 18000));

  const final: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  if (final.isSome) {
    console.log(`\n✓✓✓ ${EVM_DEPLOYER} WHITELISTED`);
  } else {
    // Check what happened
    console.log(`\n⚠ Not whitelisted. Checking recent events...`);
    const now = (await api.rpc.chain.getHeader()).number.toNumber();
    for (let b = now - 10; b <= now; b++) {
      const hash = await api.rpc.chain.getBlockHash(b);
      const apiAt = await api.at(hash);
      const events: any = await apiAt.query.system.events();
      const relevant = events.filter((e: any) =>
        ["scheduler", "whitelist", "evmAccounts"].includes(e.event.section.toString())
      );
      for (const e of relevant) {
        console.log(`  [${b}] ${e.event.section}.${e.event.method}: ${JSON.stringify(e.event.data.toHuman()).slice(0, 300)}`);
      }
    }
  }
  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
