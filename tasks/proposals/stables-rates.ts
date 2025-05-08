// @ts-nocheck
import {
  aaveManagerCall,
  generateProposalV2,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";

task(`stables-rates`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  const review = {
    fix: true,
    batch: true,
    checkOnly: "USDT,USDC",
  };

  console.log("update supply caps");
  await hre.run("review-supply-caps", review);
  await hre.run("review-borrow-caps", review);

  console.log("update rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  let proposal = await generateProposalV2(txs, false);

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("proposal:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("proposal hash:");
  console.log(proposal.hash.toHex());
});
