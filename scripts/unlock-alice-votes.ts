// One-off: unlock Alice's HDX on 0.lark by removing her votes on already-approved
// referendums and unlocking each conviction-voting track.
//
// Not related to the BIL flow — kept here so the submit-bil-proposal.ts stays
// focused on the proposal. Run once, then retire.
//
//   PROPOSAL_WS=wss://0.lark.hydration.cloud \
//   npx ts-node scripts/unlock-alice-votes.ts
//
// Needs no hardhat env — this is a pure substrate cleanup.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";

const WS = process.env.PROPOSAL_WS || "wss://0.lark.hydration.cloud";
const HDX = 10n ** 12n;

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const before = await api.query.system.account(alice.address);
  console.log(
    `Alice before: free=${before.data.free.toBigInt() / HDX} HDX, frozen=${before.data.frozen.toBigInt() / HDX} HDX`
  );

  const entries = await api.query.convictionVoting.votingFor.entries(alice.address);
  const calls: any[] = [];
  const tracks = new Set<number>();

  for (const [key, voting] of entries) {
    const track = (key.args[1] as any).toNumber();
    const v: any = voting.toJSON();
    if (!v?.casting) continue;
    const votes = v.casting.votes || [];
    for (const [refIdx] of votes) {
      calls.push(api.tx.convictionVoting.removeVote(track, refIdx));
      tracks.add(track);
    }
  }
  for (const track of tracks) {
    calls.push(api.tx.convictionVoting.unlock(track, alice.address));
  }

  console.log(`Built ${calls.length} calls across ${tracks.size} tracks`);
  if (calls.length === 0) {
    console.log("Nothing to do.");
    await api.disconnect();
    return;
  }

  const nonce = (await api.rpc.system.accountNextIndex(alice.address)) as any;
  await new Promise<void>((resolve, reject) => {
    api.tx.utility
      .batchAll(calls)
      .signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
        if (status.isInBlock) console.log(`in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
        if (!(status.isInBlock || status.isFinalized)) return;
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
        resolve();
      })
      .catch(reject);
  });
  console.log("batchAll OK");

  const after = await api.query.system.account(alice.address);
  console.log(
    `Alice after:  free=${after.data.free.toBigInt() / HDX} HDX, frozen=${after.data.frozen.toBigInt() / HDX} HDX`
  );

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
