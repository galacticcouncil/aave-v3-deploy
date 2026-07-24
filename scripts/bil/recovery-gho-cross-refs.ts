// Recovery proposal for the BIL HOLLAR-side cross-refs that the
// submit-bil-proposal.ts batch failed to set due to gotcha #10
// (nonce-prediction trap when a prior batch silent-reverted).
//
// What's broken on lark2 after Phase 7 attempts 1-3:
//   - Real GhoAToken proxy:    0x4eDd0d8cf03aC94F9c6D3a5424023498b9ac250c (deployed)
//   - Real GhoVariableDebt:    0x8Ba27f3761341D622574a70abD1EAe75845b5045 (deployed)
//   - HOLLAR.getFacilitator(realGhoAToken) → cap=0, label="" (NOT registered properly)
//   - GhoAToken.getVariableDebtToken() = 0x0
//   - GhoAToken.getGhoTreasury()       = 0x0
//   - varDebt.getAToken()              = 0x0
//   - varDebt.getDiscountToken()       = 0x0
//   - varDebt.getDiscountRateStrategy()= 0x0
//
// This proposal builds the 6 cross-ref calls as a single batchAll, wraps each
// in dispatcher.dispatchAsAaveManager (so the aave-admin origin is correct),
// and submits via the Alice TC + WhitelistedCaller ref pattern that the rest
// of the lark scripts use.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import hre from "hardhat";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";

// On-chain addresses observed via .audit-phase7.js (Phase 7.5):
const REAL_GHO_ATOKEN = "0x4eDd0d8cf03aC94F9c6D3a5424023498b9ac250c";
const REAL_VAR_DEBT   = "0x8Ba27f3761341D622574a70abD1EAe75845b5045";
const HOLLAR          = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const ZERO_DISCOUNT_RATE_STRATEGY = "0x33A7C640140FEBafEcC9801AF723A0C14420eEd7";

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
  const { generateProposalV2, getApi, aaveManagerCall } = await import(
    "../../helpers/hydration-proposal.js"
  );
  const { addTransaction, getBatch, clearBatch } = await import(
    "../../helpers/transaction-batch"
  );
  const { POOL_ADMIN, TREASURY_PROXY_ID, FORK } = await import("../../helpers");

  const hhre = hre as any;
  const { utils } = hhre.ethers;
  const networkId = FORK ? FORK : hhre.network.name;
  const admin = POOL_ADMIN[networkId];
  const apiInst = await getApi();
  const { deployer } = await hhre.getNamedAccounts();
  const signer = await hhre.ethers.getSigner(deployer);

  const treasuryAddress = (await hhre.deployments.get(TREASURY_PROXY_ID)).address;
  const ghoATokenAbi = (await hhre.deployments.get("GhoAToken-BIL")).abi;
  const ghoVarDebtAbi = (await hhre.deployments.get("GhoVariableDebtToken-BIL")).abi;
  const hollarAbi = (await hhre.deployments.get("HOLLAR")).abi;

  console.log("Recovery target addresses:");
  console.log("  HOLLAR:                  ", HOLLAR);
  console.log("  Real GhoAToken proxy:    ", REAL_GHO_ATOKEN);
  console.log("  Real GhoVariableDebt:    ", REAL_VAR_DEBT);
  console.log("  Treasury proxy:          ", treasuryAddress);
  console.log("  ZeroDiscountRateStrategy:", ZERO_DISCOUNT_RATE_STRATEGY);

  // 6 recovery calls
  const hollar = new hhre.ethers.Contract(HOLLAR, hollarAbi, signer);
  const ghoAToken = new hhre.ethers.Contract(REAL_GHO_ATOKEN, ghoATokenAbi, signer);
  const varDebt = new hhre.ethers.Contract(REAL_VAR_DEBT, ghoVarDebtAbi, signer);

  const bucketCapacity = utils.parseUnits("1.0", 24); // 1M HOLLAR (18 decimals scaled to 24)

  addTransaction(
    await hollar.populateTransaction.addFacilitator(
      REAL_GHO_ATOKEN,
      "BIL-GhoAToken",
      bucketCapacity,
      { gasLimit: 500_000 }
    )
  );
  addTransaction(await ghoAToken.populateTransaction.setVariableDebtToken(REAL_VAR_DEBT));
  addTransaction(await ghoAToken.populateTransaction.updateGhoTreasury(treasuryAddress));
  addTransaction(await varDebt.populateTransaction.setAToken(REAL_GHO_ATOKEN));
  addTransaction(await varDebt.populateTransaction.updateDiscountRateStrategy(ZERO_DISCOUNT_RATE_STRATEGY));
  addTransaction(await varDebt.populateTransaction.updateDiscountToken(HOLLAR));

  const txs = await Promise.all(
    getBatch().map((tx: any) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  console.log(`\n${txs.length} EVM calls wrapped in dispatcher.dispatchAsAaveManager`);

  const { whitelistedCall, proposal } = await generateProposalV2(txs, true);
  console.log(`whitelistedCall.hash: ${whitelistedCall.hash.toHex()}`);
  console.log(`proposal.hash:        ${proposal.hash.toHex()}`);
  console.log(`proposal.length:      ${proposal.encodedLength}`);

  // Submit via the same TC + WhitelistedCaller ref pattern used elsewhere
  const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  // 1. TC propose(whitelist.whitelistCall)
  const wlAlready: any = await api.query.whitelist.whitelistedCall(whitelistedCall.hash);
  if (!wlAlready.isSome) {
    const wlCall = api.tx.whitelist.whitelistCall(whitelistedCall.hash);
    await signAndWait(
      api.tx.technicalCommittee.propose(1, wlCall, wlCall.method.encodedLength),
      alice,
      api,
      "TC propose(whitelist.whitelistCall)"
    );
  } else {
    console.log("  (already whitelisted)");
  }

  // 2. notePreimage(proposal)
  const preReq: any = await api.query.preimage.requestStatusFor(proposal.hash);
  const preOld: any = await api.query.preimage.statusFor(proposal.hash);
  if (!preReq.isSome && !preOld.isSome) {
    await signAndWait(
      api.tx.preimage.notePreimage(proposal.toHex()),
      alice,
      api,
      "preimage.notePreimage"
    );
  } else {
    console.log("  (preimage already noted)");
  }

  // 3. referenda.submit on WhitelistedCaller track
  const events = await signAndWait(
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: proposal.hash, len: proposal.encodedLength } },
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
  console.log(`Referendum: ${refIndex}`);

  await signAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api,
    "placeDecisionDeposit"
  );

  // 4. Vote — 4B against `free` (not `free - frozen`) per gotcha #2 / Ben's rule
  const MAX_VOTE = 4_000_000_000n * 10n ** 12n;
  const bal: any = await api.query.system.account(alice.address);
  const free = bal.data.free.toBigInt();
  const voteBalance = (free < MAX_VOTE ? free : MAX_VOTE).toString();
  console.log(`voting with ${(BigInt(voteBalance) / 10n ** 12n).toString()} HDX (4B cap)`);
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote"
  );

  // 5. Poll for approval
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!info.isSome) continue;
    const r = info.unwrap();
    console.log(`  [${i}] ${r.type}`);
    if (r.isApproved) break;
    if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled)
      throw new Error(`${r.type}`);
  }

  console.log("Waiting 18s for enactment...");
  await new Promise((r) => setTimeout(r, 18000));

  // 6. Verify recovery state
  const ghoATokenView = new hhre.ethers.Contract(REAL_GHO_ATOKEN, [
    "function getVariableDebtToken() view returns (address)",
    "function getGhoTreasury() view returns (address)",
  ], hhre.ethers.provider);
  const varDebtView = new hhre.ethers.Contract(REAL_VAR_DEBT, [
    "function getAToken() view returns (address)",
    "function getDiscountToken() view returns (address)",
    "function getDiscountRateStrategy() view returns (address)",
  ], hhre.ethers.provider);
  const hollarView = new hhre.ethers.Contract(HOLLAR, hollarAbi, hhre.ethers.provider);

  const fac = await hollarView.getFacilitator(REAL_GHO_ATOKEN);
  console.log("\nVERIFY:");
  console.log("  HOLLAR.getFacilitator.label:           ", fac.label);
  console.log("  HOLLAR.getFacilitator.bucketCapacity:  ", fac.bucketCapacity.toString());
  console.log("  GhoAToken.getVariableDebtToken:        ", await ghoATokenView.getVariableDebtToken());
  console.log("  GhoAToken.getGhoTreasury:              ", await ghoATokenView.getGhoTreasury());
  console.log("  varDebt.getAToken:                     ", await varDebtView.getAToken());
  console.log("  varDebt.getDiscountToken:              ", await varDebtView.getDiscountToken());
  console.log("  varDebt.getDiscountRateStrategy:       ", await varDebtView.getDiscountRateStrategy());

  await api.disconnect();
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(`FAILED: ${e.message}`);
    process.exit(1);
  });
