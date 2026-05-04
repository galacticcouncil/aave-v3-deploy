// Point pallet-liquidation.gigaHdxPoolContract at our Pool-Proxy-GIGAHDX on lark 1.
// Uses same whitelisted_caller + Alice 6x conviction pattern that just worked for the
// runtime upgrade. Origin needed: EitherOf<EnsureRoot, GeneralAdmin> — WhitelistedCaller
// track dispatches with Root.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import * as fs from "fs";
import * as path from "path";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
// Auto-resolve Pool-Proxy-GIGAHDX from deployments/lark2/ (the freshly-deployed
// hardhat artifact). Override via GIGAHDX_POOL env var if needed.
function resolveGigaHdxPool(): string {
	if (process.env.GIGAHDX_POOL) return process.env.GIGAHDX_POOL;
	const p = path.join(__dirname, "..", "..", "deployments", "lark2", "Pool-Proxy-GIGAHDX.json");
	if (!fs.existsSync(p)) {
		throw new Error(`Pool-Proxy-GIGAHDX.json not found at ${p}; set GIGAHDX_POOL env var`);
	}
	return JSON.parse(fs.readFileSync(p, "utf8")).address;
}
const GIGAHDX_POOL = resolveGigaHdxPool();
// Vote cap per Ben's rule. 4B HDX is well above any track's approval threshold
// on Hydration (total issuance ~6.5B) and avoids locking Alice's entire balance.
const MAX_VOTE_BASE = 4_000_000_000n * 10n ** 12n;

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
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const current: any = await api.query.liquidation.gigaHdxPoolContract();
  console.log(`current gigaHdxPoolContract: ${current.toString()}`);
  if (current.toString().toLowerCase() === GIGAHDX_POOL.toLowerCase()) {
    console.log("already set correctly");
    await api.disconnect();
    return;
  }

  // Inner call
  const innerCall = api.tx.liquidation.setGigahdxPoolContract(GIGAHDX_POOL);
  const innerHash = innerCall.method.hash.toHex();
  console.log(`inner setGigahdxPoolContract hash: ${innerHash}`);

  // TC whitelist
  const wl: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wl.isSome) {
    const wlCall = api.tx.whitelist.whitelistCall(innerHash);
    await signAndWait(
      api.tx.technicalCommittee.propose(1, wlCall, wlCall.method.encodedLength),
      alice,
      api,
      "TC propose(whitelist.whitelistCall)"
    );
  } else {
    console.log("inner already whitelisted");
  }

  // Wrapper
  const wrapper = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
  const wrapperHex = wrapper.method.toHex();
  const wrapperHash = wrapper.method.hash.toHex();
  const wrapperLen = wrapper.method.encodedLength;
  console.log(`wrapper hash: ${wrapperHash} len: ${wrapperLen}`);

  const preReq: any = await api.query.preimage.requestStatusFor(wrapperHash);
  const preOld: any = await api.query.preimage.statusFor(wrapperHash);
  if (!preReq.isSome && !preOld.isSome) {
    await signAndWait(
      api.tx.preimage.notePreimage(wrapperHex),
      alice,
      api,
      "preimage.notePreimage"
    );
  } else {
    console.log("wrapper preimage already noted");
  }

  // Submit ref
  const events = await signAndWait(
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: wrapperHash, len: wrapperLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit(WhitelistedCaller)"
  );
  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no Submitted event");
  console.log(`ref: ${refIndex}`);

  await signAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api,
    "placeDecisionDeposit"
  );

  // Vote with min(full free balance, 4B cap) at 6x. Same-class lock is max-ed so
  // we can vote up to our total balance on a different ref without extra lock.
  const bal: any = await api.query.system.account(alice.address);
  const free = bal.data.free.toBigInt();
  const voteBalance = (free < MAX_VOTE_BASE ? free : MAX_VOTE_BASE).toString();
  console.log(
    `voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX at 6x ` +
      `(free=${Number(free / 10n ** 12n).toLocaleString()}, cap=4B)`
  );
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote"
  );

  // Poll
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!info.isSome) continue;
    const r = info.unwrap();
    console.log(`  [${i}] ${r.type}`);
    if (r.isApproved) break;
    if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled)
      throw new Error(`${r.type}`);
  }

  console.log("waiting 15s for enactment...");
  await new Promise((r) => setTimeout(r, 15000));

  const final: any = await api.query.liquidation.gigaHdxPoolContract();
  console.log(`\ngigaHdxPoolContract now: ${final.toString()}`);
  if (final.toString().toLowerCase() === GIGAHDX_POOL.toLowerCase()) {
    console.log("✓✓✓ gigaHdxPoolContract set correctly");
  } else {
    console.log("⚠ still not set — check events");
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(`FAILED: ${e.message}`);
  process.exit(1);
});
