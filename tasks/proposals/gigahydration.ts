// @ts-nocheck
import {
  aaveManagerCall,
  generateProposal,
  generateProposalV2,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`gigahydration`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  console.log("update caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });
  await hre.run("review-borrow-caps", { fix: true, batch: true });

  console.log("update incentives");
  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-GDOT",
    //incentivize: aToken,
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
