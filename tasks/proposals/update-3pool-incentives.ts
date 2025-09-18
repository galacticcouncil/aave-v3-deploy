// @ts-nocheck
import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-3pool-incentives`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  await hre.run("review-incentive", {
    batch: true,
    reserve: "3-POOL",
  });

  const proposal = await generateProposal(getBatch(), admin, []);

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("proposal hash:");
  console.log(proposal.hash.toHex());
});
