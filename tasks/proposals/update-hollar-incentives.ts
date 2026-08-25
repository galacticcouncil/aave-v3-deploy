// @ts-nocheck
import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-hollar-incentives`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDC",
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDT",
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDS",
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDE",
  });

  const proposal = await generateProposal(getBatch(), admin, []);

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("proposal hash:");
  console.log(proposal.hash.toHex());
});
