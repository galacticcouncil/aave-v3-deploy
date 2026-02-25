// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import { FORK, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-dot-emode`, ``).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  console.log("update DOT emode");
  await hre.run("review-e-mode", {
    name: "DotEMode",
    fix: true,
    batch: true,
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
