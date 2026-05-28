// One-off patch: bring lark-2 HDCL into line with the updated defaults
//   - DCL: baseLTV 70%→80%, liqThreshold 80%→85% (bonus + protocol fee unchanged)
//   - HOLLAR borrow rate: 9.53% APR (old 10% APY conversion) → flat 10% APR
//
// Mainnet won't need this — it'll pick up the new values from the source-of-truth
// configs at first deploy. lark-2 was already governance-enacted with the old
// values, so this script deploys a fresh GhoInterestRateStrategy and submits a
// Root-track patch proposal swapping LTV/LT + rate strategy.
//
// Usage:
//   MARKET_NAME=HDCL HARDHAT_NETWORK=lark2 PROPOSAL_WS=wss://2.lark.hydration.cloud \
//     npx hardhat run scripts/patch-hdcl-params-lark2.ts --network lark2

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import hre from "hardhat";

const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const DCL = "0x0000000000000000000000000000000100000226"; // asset 550 precompile

const NEW_LTV = 8000;            // 80%
const NEW_LIQ_THRESHOLD = 8500;  // 85%
const LIQ_BONUS_UNCHANGED = 10700;
const NEW_BORROW_RATE_RAY = 10n ** 26n; // 10% APR in ray (1e27 → 0.1)

const PROPOSAL_WS = process.env.PROPOSAL_WS || "ws://localhost:8000";
const IS_CHOPSTICKS = PROPOSAL_WS.includes("localhost") || PROPOSAL_WS.includes("127.0.0.1");

async function devNewBlock(api: ApiPromise, n = 1) {
  for (let i = 0; i < n; i++) await (api as any)._rpcCore.provider.send("dev_newBlock", [{}]);
}

async function setInstantBlockMode(api: ApiPromise) {
  if (!IS_CHOPSTICKS) return;
  await (api as any)._rpcCore.provider.send("dev_setBlockBuildMode", ["Instant"]);
}

async function unfreezeAlice(api: ApiPromise, alice: any) {
  if (!IS_CHOPSTICKS) return;
  const accountKey = api.query.system.account.key(alice.address);
  const locksKey = api.query.balances.locks.key(alice.address);
  const freezesKey = api.query.balances.freezes.key(alice.address);
  const acc = await api.query.system.account(alice.address);
  const nonce = (acc as any).nonce.toNumber();
  const MIN_FREE = 5_000_000_000n * 10n ** 12n;
  const cur = (acc as any).data.free.toBigInt() as bigint;
  const target = cur > MIN_FREE ? cur : MIN_FREE;
  const info = api.registry.createType("AccountInfo", {
    nonce, consumers: 0, providers: 1, sufficients: 0,
    data: { free: target.toString(), reserved: "0", frozen: "0", flags: "0" },
  });
  const empty = api.registry.createType("Vec<BalanceLock>", []);
  await (api as any)._rpcCore.provider.send("dev_setStorage", [[
    [accountKey, u8aToHex(info.toU8a())],
    [locksKey, u8aToHex(empty.toU8a())],
    [freezesKey, null],
  ]]);
}

async function signAndWait(tx: SubmittableExtrinsic<"promise">, signer: any, api: ApiPromise, label: string): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  const nonce = (await api.rpc.system.accountNextIndex(signer.address)) as any;
  return new Promise((resolve, reject) => {
    let unsub: any;
    tx.signAndSend(signer, { nonce }, async ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        if (dispatchError.isModule) {
          const d = api.registry.findMetaError(dispatchError.asModule);
          unsub?.(); return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
        }
        unsub?.(); return reject(new Error(dispatchError.toString()));
      }
      for (const { event } of events) {
        if (event.section === "system" && event.method === "ExtrinsicFailed") {
          unsub?.(); return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
        }
      }
      console.log(`  OK`);
      unsub?.(); resolve(events as any[]);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  const hhre = hre as any;
  const eth = hhre.ethers;
  const { deployer } = await hhre.getNamedAccounts();
  const signer = await eth.getSigner(deployer);

  const aaveProposal = await import("../helpers/hydration-proposal.js");
  const { generateProposalV2, getApi, aaveManagerCall } = aaveProposal;

  const { POOL_ADMIN, FORK } = await import("../helpers");
  const networkId = FORK ? FORK : hhre.network.name;
  const admin = POOL_ADMIN[networkId];

  // -------- Deploy fresh GhoInterestRateStrategy with the new APR --------
  const oldStrategy = await hhre.deployments.get("GhoInterestRateStrategy-HDCL");
  const provider = (await hhre.deployments.get("PoolAddressesProvider-HDCL")).address;
  const newRateAmount = NEW_BORROW_RATE_RAY.toString();
  console.log(`deploying new GhoInterestRateStrategy (provider=${provider}, rate=${newRateAmount} ray = 10% APR)`);
  const Factory = new eth.ContractFactory(oldStrategy.abi, oldStrategy.bytecode, signer);
  const newStrategy = await Factory.deploy(provider, newRateAmount, { gasLimit: 3_000_000 });
  await newStrategy.deployed();
  console.log(`new strategy @ ${newStrategy.address}`);
  // Sanity-read the new rate
  const readBack = await newStrategy.getBaseVariableBorrowRate();
  console.log(`  getBaseVariableBorrowRate -> ${readBack.toString()}`);

  // -------- Build the patch proposal --------
  // 1. PoolConfigurator.configureReserveAsCollateral(DCL, ltv, liqThreshold, liqBonus)
  // 2. PoolConfigurator.setReserveInterestRateStrategyAddress(HOLLAR, newStrategy)
  const poolConfigurator = await eth.getContractAt(
    [
      "function configureReserveAsCollateral(address asset, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus)",
      "function setReserveInterestRateStrategyAddress(address asset, address rateStrategyAddress)",
    ],
    (await hhre.deployments.get("PoolConfigurator-Proxy-HDCL")).address
  );

  const txCollateral = await poolConfigurator.populateTransaction.configureReserveAsCollateral(
    DCL, NEW_LTV, NEW_LIQ_THRESHOLD, LIQ_BONUS_UNCHANGED, { gasLimit: 1_000_000 }
  );
  const txRateSwap = await poolConfigurator.populateTransaction.setReserveInterestRateStrategyAddress(
    HOLLAR, newStrategy.address, { gasLimit: 500_000
  });

  const txs = await Promise.all([
    aaveManagerCall({ ...txCollateral, from: admin }),
    aaveManagerCall({ ...txRateSwap, from: admin }),
  ]);
  // No substrate ordering issue this time — the underlyings are already
  // registered, so EVM-only calls are fine in any order.

  const batchAllCall = await generateProposalV2(txs, false);
  console.log(`\nbatchAll.hash:   ${batchAllCall.hash.toHex()}`);
  console.log(`batchAll.length: ${batchAllCall.encodedLength}`);

  // -------- Submit --------
  const api = await ApiPromise.create({ provider: new WsProvider(PROPOSAL_WS) });
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  await setInstantBlockMode(api);
  await unfreezeAlice(api, alice);

  const proposalHash = batchAllCall.hash.toHex();
  const proposalHex = batchAllCall.toHex();
  const proposalLen = batchAllCall.encodedLength;

  try {
    await signAndWait(api.tx.preimage.notePreimage(proposalHex), alice, api, "preimage.notePreimage(patch)");
  } catch (e: any) {
    if (!/AlreadyNoted/i.test(e?.message ?? "")) throw e;
    console.log("preimage already noted — continuing");
  }

  const events = await signAndWait(
    api.tx.referenda.submit(
      { system: "Root" },
      { Lookup: { hash: proposalHash, len: proposalLen } },
      { After: 1 }
    ),
    alice, api, "referenda.submit(Root)"
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
  const voteBalance = (BigInt(4_000_000_000) * BigInt(10 ** 12)).toString();
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance } }),
    alice, api, "convictionVoting.vote"
  );

  if (IS_CHOPSTICKS) {
    for (let i = 0; i < 200; i++) {
      await devNewBlock(api, 1);
      const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
      if (ref.isSome) {
        const info = ref.unwrap();
        if (info.isApproved) { console.log(`  approved after ~${i} blocks`); break; }
        if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
          throw new Error(`ref ${refIndex} ${info.type}`);
        }
      }
    }
    await devNewBlock(api, 30);
  } else {
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 3000));
      const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
      if (!ref.isSome) continue;
      const info = ref.unwrap();
      console.log(`[${i}] ${info.type}`);
      if (info.isApproved) break;
      if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
        throw new Error(`ref ${refIndex} ${info.type}`);
      }
    }
    await new Promise((r) => setTimeout(r, 18000));
  }

  // -------- Scan events --------
  const head = (await api.rpc.chain.getHeader()).number.toNumber();
  console.log(`\n=== scanning events in blocks ${Math.max(0, head - 20)}..${head} ===`);
  for (let b = Math.max(0, head - 20); b <= head; b++) {
    const hash = await api.rpc.chain.getBlockHash(b);
    const apiAt = await api.at(hash);
    const events: any = await apiAt.query.system.events();
    const relevant = events.filter((e: any) =>
      ["dispatcher", "evm", "utility"].includes(e.event.section.toString())
    );
    for (const e of relevant) {
      const ev = e.event;
      const data = JSON.stringify(ev.data.toHuman()).slice(0, 200);
      console.log(`  [${b}] ${ev.section}.${ev.method}: ${data}`);
    }
  }

  await api.disconnect();
  console.log("\nDone.");
}

main().catch((e) => { console.error(e); process.exit(1); });
