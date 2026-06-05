// Submit the HDCL stablepool launch proposal end-to-end. Defaults to
// chopsticks (ws://localhost:8000) for dry-run; set
// PROPOSAL_WS=wss://0.lark.hydration.cloud to run against the real testnet.
//
// Mirrors the flow of submit-hdcl-proposal.ts but uses a different proposal
// payload (the new stablepool launch), and submits on the Root track only
// (no whitelist wrapping — non-urgent proposal per the user's policy).
//
// Flow:
//   0. Build the proposal preimage via buildHdclStablepoolProposal().
//   1. Note the proposal preimage.
//   2. Submit a Root-track referendum.
//   3. Alice places decision deposit + votes aye with full conviction.
//   4. On chopsticks: fast-forward via dev_newBlock. On real chain: poll.
//   5. Scan recent block events for success/failure markers.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import hre from "hardhat";

import { buildHdclStablepoolProposal } from "../tasks/proposals/hdcl-stablepool-lark";

const PROPOSAL_WS = process.env.PROPOSAL_WS || "ws://localhost:8000";
const IS_CHOPSTICKS =
  PROPOSAL_WS.includes("localhost") || PROPOSAL_WS.includes("127.0.0.1");

async function devNewBlock(api: ApiPromise, count = 1) {
  for (let i = 0; i < count; i++) {
    await (api as any)._rpcCore.provider.send("dev_newBlock", [{}]);
  }
}

// Flip chopsticks to Instant block-build so each tx auto-seals a block.
// Default (Manual) makes signAndWait deadlock on isInBlock; --build-block-mode=Instant
// fails at startup ("Failed to apply inherents"); flipping it at runtime via RPC works.
async function setInstantBlockModeOnChopsticks(api: ApiPromise) {
  if (!IS_CHOPSTICKS) return;
  await (api as any)._rpcCore.provider.send("dev_setBlockBuildMode", ["Instant"]);
  console.log("chopsticks: block-build mode → Instant");
}

// On chopsticks: Alice's mainnet-forked state has all her HDX locked behind
// an unrelated conviction-voting lock. Unfreeze her so she can submit +
// deposit + vote on this referendum.
async function unfreezeAliceOnChopsticks(
  api: ApiPromise,
  alice: any
): Promise<void> {
  if (!IS_CHOPSTICKS) return;
  console.log("\n--- unfreezing Alice on chopsticks ---");
  const accountKey = api.query.system.account.key(alice.address);
  const locksKey = api.query.balances.locks.key(alice.address);
  const freezesKey = api.query.balances.freezes.key(alice.address);
  const acc = await api.query.system.account(alice.address);
  const nonce = (acc as any).nonce.toNumber();
  // Take max(current, 5B HDX) — gc chopsticks' hydradx.yml import-storage
  // clobbers Alice to ~1000 HDX, but we need 4B+ for the Root-track vote.
  const HDX_MIN_FREE = 5_000_000_000n * 10n ** 12n;
  const currentFree = (acc as any).data.free.toBigInt() as bigint;
  const targetFree = currentFree > HDX_MIN_FREE ? currentFree : HDX_MIN_FREE;
  const newAccountInfo = api.registry.createType("AccountInfo", {
    nonce,
    consumers: 0,
    providers: 1,
    sufficients: 0,
    data: {
      free: targetFree.toString(),
      reserved: "0",
      frozen: "0",
      flags: "0",
    },
  });
  const emptyVec = api.registry.createType("Vec<BalanceLock>", []);
  await (api as any)._rpcCore.provider.send("dev_setStorage", [
    [
      [accountKey, u8aToHex(newAccountInfo.toU8a())],
      [locksKey, u8aToHex(emptyVec.toU8a())],
      [freezesKey, null],
    ],
  ]);
  const bal2: any = await api.query.system.account(alice.address);
  const free = bal2.data.free.toBigInt();
  const frozen = bal2.data.frozen.toBigInt();
  console.log(
    `  Alice free=${(free / 10n ** 12n).toString()} HDX, ` +
      `frozen=${(frozen / 10n ** 12n).toString()} HDX`
  );
}

async function signAndWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  const nonce = (await api.rpc.system.accountNextIndex(signer.address)) as any;
  return new Promise((resolve, reject) => {
    let unsub: any;
    tx.signAndSend(
      signer,
      { nonce },
      async ({ status, dispatchError, events }) => {
        if (status.isInBlock)
          console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
        if (status.isFinalized || status.isInBlock) {
          if (dispatchError) {
            if (dispatchError.isModule) {
              const decoded = api.registry.findMetaError(
                dispatchError.asModule
              );
              const msg = `${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`;
              console.log(`  dispatchError: ${msg}`);
              if (unsub) unsub();
              reject(new Error(msg));
              return;
            } else {
              const msg = dispatchError.toString();
              console.log(`  dispatchError: ${msg}`);
              if (unsub) unsub();
              reject(new Error(msg));
              return;
            }
          }
          for (const { event } of events) {
            console.log(`  event: ${event.section}.${event.method}`);
          }
          if (unsub) unsub();
          resolve(events);
        }
      }
    ).then((u) => {
      unsub = u;
    });
  });
}

async function main() {
  console.log(`PROPOSAL_WS = ${PROPOSAL_WS}`);
  console.log(`IS_CHOPSTICKS = ${IS_CHOPSTICKS}`);

  // -------- 0. Build the proposal preimage --------
  // Re-uses the same logic as the `hdcl-stablepool-lark` hardhat task.
  const batchAllCall = await buildHdclStablepoolProposal(hre);

  // -------- Switch to the submission RPC (chopsticks or 0.lark) --------
  const api = await ApiPromise.create({
    provider: new WsProvider(PROPOSAL_WS),
    noInitWarn: true,
  });
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  console.log(`Alice: ${alice.address}`);

  const proposalHash = batchAllCall.hash.toHex();
  const proposalHex = batchAllCall.toHex();
  const proposalLen = batchAllCall.encodedLength;
  console.log(`proposal hash:   ${proposalHash}`);
  console.log(`proposal length: ${proposalLen}`);

  await setInstantBlockModeOnChopsticks(api);
  await unfreezeAliceOnChopsticks(api, alice);

  // -------- 1. Note proposal preimage --------
  try {
    await signAndWait(
      api.tx.preimage.notePreimage(proposalHex),
      alice,
      api,
      "preimage.notePreimage(stablepool-batchAll)"
    );
  } catch (e: any) {
    if (!/AlreadyNoted/i.test(e?.message ?? "")) throw e;
    console.log("Proposal preimage already noted — continuing");
  }

  // -------- 2. Submit referendum on Root track --------
  const events = await signAndWait(
    api.tx.referenda.submit(
      { system: "Root" },
      { Lookup: { hash: proposalHash, len: proposalLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit(Root track)"
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

  // -------- 3. Decision deposit + vote aye with full conviction --------
  await signAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api,
    "placeDecisionDeposit"
  );
  // 4B HDX — enough to instantly confirm on lark's Root track.
  const voteBalance = (BigInt(4_000_000_000) * BigInt(10 ** 12)).toString();
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: {
        vote: { aye: true, conviction: "Locked6x" },
        balance: voteBalance,
      },
    }),
    alice,
    api,
    "convictionVoting.vote"
  );

  // -------- 4. Poll / fast-forward --------
  if (IS_CHOPSTICKS) {
    console.log(
      "\nFast-forwarding blocks on chopsticks until approval + enactment..."
    );
    for (let i = 0; i < 200; i++) {
      await devNewBlock(api, 1);
      const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
      if (ref.isSome) {
        const info = ref.unwrap();
        if (info.isApproved) {
          console.log(`  approved after ~${i} blocks`);
          break;
        }
        if (
          info.isRejected ||
          info.isCancelled ||
          info.isTimedOut ||
          info.isKilled
        ) {
          throw new Error(`Ref ${refIndex} ${info.type}`);
        }
      }
    }
    console.log("  Building further blocks for enactment + scheduled batch...");
    // Need extra blocks for the scheduler.scheduleAfter(1) inside our
    // batchAll to fire (post pool-creation bootstrap).
    await devNewBlock(api, 30);
  } else {
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 3000));
      const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
      if (!ref.isSome) continue;
      const info = ref.unwrap();
      console.log(`[${i}] ${info.type}`);
      if (info.isApproved) break;
      if (
        info.isRejected ||
        info.isCancelled ||
        info.isTimedOut ||
        info.isKilled
      ) {
        throw new Error(`Ref ${refIndex} ${info.type}`);
      }
    }
    console.log("Waiting 60s for enactment + scheduled batch...");
    await new Promise((r) => setTimeout(r, 60000));
  }

  // -------- 5. Scan recent block events for outcome --------
  const head = (await api.rpc.chain.getHeader()).number.toNumber();
  const fromBlock = Math.max(0, head - 50);
  console.log(`\n=== scanning events in blocks ${fromBlock}..${head} ===`);

  let executedFailedCount = 0;
  let batchInterruptedCount = 0;
  let dispatchErrorCount = 0;
  const RELEVANT_SECTIONS = [
    "scheduler",
    "whitelist",
    "dispatcher",
    "assetRegistry",
    "evm",
    "utility",
    "multiTransactionPayment",
    "stableswap",
    "tokens",
    "currencies",
    "system",
  ];

  for (let b = fromBlock; b <= head; b++) {
    const hash = await api.rpc.chain.getBlockHash(b);
    const apiAt = await api.at(hash);
    const events: any = await apiAt.query.system.events();
    for (const e of events) {
      const ev = e.event;
      if (!RELEVANT_SECTIONS.includes(ev.section.toString())) continue;
      const section = ev.section.toString();
      const method = ev.method.toString();

      if (section === "evm" && method === "ExecutedFailed") {
        executedFailedCount++;
      }
      if (section === "utility" && method === "BatchInterrupted") {
        batchInterruptedCount++;
      }
      if (
        section === "system" &&
        (method === "ExtrinsicFailed" || method === "DispatchError")
      ) {
        dispatchErrorCount++;
      }

      const data = JSON.stringify(ev.data.toHuman()).slice(0, 280);
      console.log(`  [${b}] ${section}.${method}: ${data}`);
    }
  }

  console.log(`\n=== Failure marker summary ===`);
  console.log(`  evm.ExecutedFailed:        ${executedFailedCount}`);
  console.log(`  utility.BatchInterrupted:  ${batchInterruptedCount}`);
  console.log(`  system.ExtrinsicFailed:    ${dispatchErrorCount}`);
  if (executedFailedCount + batchInterruptedCount + dispatchErrorCount > 0) {
    console.log(`  *** PROPOSAL HAD FAILURES — review events above ***`);
  } else {
    console.log(`  *** Clean execution — no failure markers ***`);
  }

  // -------- 6. Post-state verification --------
  console.log(`\n=== Post-state verification ===`);
  const lpInfo: any = await api.query.assetRegistry.assets(10055);
  console.log(
    `  assetRegistry.assets(10055): ${
      lpInfo.isSome ? JSON.stringify(lpInfo.toHuman()) : "<not registered>"
    }`
  );
  const lpFee: any =
    await api.query.multiTransactionPayment.acceptedCurrencies(10055);
  console.log(
    `  multiTransactionPayment.acceptedCurrencies(10055): ${
      lpFee.isSome ? lpFee.unwrap().toString() : "<not accepted>"
    }`
  );
  try {
    const pools: any = await api.query.stableswap.pools(10055);
    console.log(
      `  stableswap.pools(10055): ${
        pools.isSome ? JSON.stringify(pools.toHuman()) : "<not exists>"
      }`
    );
  } catch (e: any) {
    console.log(`  stableswap.pools query failed: ${e.message ?? e}`);
  }
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";
  // Erc20-typed assets (HOLLAR=222, aHDCL=550) are NOT tracked in
  // orml_tokens — their balances live in the EVM contract's storage and
  // are exposed through the CurrenciesApi runtime call. Using
  // tokens.accounts here returns 0 for Erc20 assets even when there's a
  // real balance; CurrenciesApi.account routes through the precompile
  // and reads the actual EVM-side balanceOf.
  // The LP token (10055) IS native StableSwap-typed, so orml_tokens has
  // it — both queries agree on that one.
  const fmtBig = (b: any) => {
    const n = BigInt(b.free);
    return `${n.toString()} (≈ ${(Number(n) / 1e18).toFixed(4)})`;
  };
  console.log("  --- via CurrenciesApi.account (real EVM-backed balances) ---");
  for (const [label, id] of [
    ["222 (HOLLAR)", 222],
    ["550 (aHDCL)", 550],
    ["10055 (LP)", 10055],
  ] as const) {
    const acct: any = await (api as any).call.currenciesApi.account(id, treasury);
    console.log(`  treasury ${label}: ${fmtBig(acct)}`);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
