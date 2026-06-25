// @ts-nocheck
import {
  getApi,
  generateProposalV2,
  dispatchAs,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Re-seed the 2-Pool-apyUSD (146) stableswap.
//
// The original launch (block 12561497) created the pool and borrowed 500k
// HOLLAR to the treasury, but its `addAssetsLiquidity` reverted with
// stableswap.InsufficientBalance: the apyUSD seed was hardcoded to a rounded-up
// 363,156 while the treasury only held 363,155.677…, ~0.32 apyUSD short.
// `utility.dispatchAs` swallows the inner error, so the batch reported success
// and the pool was left EMPTY (LP issuance 0). The 500k HOLLAR is still idle in
// the treasury, so no new borrow is needed here.
//
// Front-running guard: while the pool is empty, anyone can be the first LP. A
// third party seeding it first (especially imbalanced, against the MMOracle peg)
// could make our fixed-amount add fail or land at a bad ratio. So this task
// emits TWO artifacts:
//
//   1. FREEZE call  — set both pool assets to Tradability{bits:0} (FROZEN).
//      Submit this NOW via the Technical Committee so nobody can add liquidity
//      while the referendum runs.
//
//   2. PROPOSAL     — (whitelisted) un-freeze both assets back to {bits:15}
//      (the default, all-enabled), THEN add the treasury's liquidity, all in one
//      atomic batch. After it runs the pool is seeded and normally tradable.
//
// Tradability bitflags (pallet_stableswap::types::Tradability):
//   SELL=1  BUY=2  ADD_LIQUIDITY=4  REMOVE_LIQUIDITY=8  →  all-on = 15, FROZEN = 0
const FROZEN = { bits: 0 };
const ENABLED = { bits: 15 };

task(
  `apyusd-liquidity`,
  `Freeze + seed the 2-Pool-apyUSD (146) stableswap with treasury HOLLAR + apyUSD`
).setAction(async function (_, hre) {
  const hydrationTx = (await getApi()).tx;

  const HOLLAR = 222;
  const APYUSD = 46;
  const poolAPYUSD = 146;
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  // Treasury already holds both seeds (verified on chain at head 12562526):
  //   HOLLAR  552,147.525  >= 500,000
  //   apyUSD  363,155.677  >= 363,155
  const hollarSeed = "500000000000000000000000"; // 500,000
  const apyUSDSeed = "363155000000000000000000"; // 363,155 (rounded down)

  const decoder = new ProposalDecoder(hre);
  await decoder.init();

  // ---- Artifact 2: whitelisted proposal — unfreeze, then seed ----
  const calls = [
    hydrationTx.stableswap.setAssetTradableState(poolAPYUSD, APYUSD, ENABLED),
    hydrationTx.stableswap.setAssetTradableState(poolAPYUSD, HOLLAR, ENABLED),
    await dispatchAs(
      treasury,
      hydrationTx.stableswap.addAssetsLiquidity(
        ...Object.values({
          poolId: poolAPYUSD,
          assets: [
            { assetId: HOLLAR, amount: hollarSeed },
            { assetId: APYUSD, amount: apyUSDSeed },
          ],
          minShares: 0,
        })
      )
    ),
  ];

  const preimage = await generateProposalV2(calls, false);
  console.log("\n=== 2) PROPOSAL (unfreeze + seed) ===");
  console.log("preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
  console.log("preimage hash (this is what the TC motion whitelists):");
  console.log(preimage.hash.toHex());

  const { proposal } = await generateProposalV2(calls, true);
  console.log("\nwhitelisted proposal (submit on Whitelisted Caller track):");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("proposal hash:");
  console.log(proposal.hash.toHex());

  // ---- Artifact 1: single Technical Committee motion ----
  // Verified on a tarn fork @ #12562526: a TC MAJORITY (>=4/7) satisfies the
  // authority origin for both setAssetTradableState and whitelist.whitelistCall
  // (3/7 -> BadOrigin, 4/7 -> Ok). One motion does both: freeze the pool now AND
  // whitelist the seed proposal above so it can run on the Whitelisted Caller
  // track. batchAll => atomic; whitelisted hash = the preimage hash above.
  const TC_THRESHOLD = 4; // majority of 7
  const tcBatch = hydrationTx.utility.batchAll([
    hydrationTx.stableswap.setAssetTradableState(poolAPYUSD, APYUSD, FROZEN),
    hydrationTx.stableswap.setAssetTradableState(poolAPYUSD, HOLLAR, FROZEN),
    hydrationTx.whitelist.whitelistCall(preimage.hash),
  ]).method;
  const tcPropose = hydrationTx.technicalCommittee.propose(
    TC_THRESHOLD,
    tcBatch,
    (tcBatch.toHex().length - 2) / 2
  ).method;
  console.log("\n=== 1) TC MOTION: freeze + whitelist (submit NOW, threshold 4/7) ===");
  console.log(tcPropose.toHex());
  decoder.printTree(decoder.transformCall(tcPropose.toHuman()));
  console.log("inner batch hash:");
  console.log(tcBatch.hash.toHex());
});
