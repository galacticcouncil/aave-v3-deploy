import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-supply-caps`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  const { preimages, whitelist, proposal, extrinsic } = await generateProposal(
    getBatch(),
    admin,
    [],
    true
  );
  console.log("submit preimages:");
  console.log(preimages.toHex());
  console.log("call:");
  console.log(extrinsic.toHex());
  console.log("whitelist call hash:", extrinsic.hash.toHex());
  console.log(whitelist.toHex());
  console.log("whitelisted proposal:");
  console.log(proposal.toHex());
  console.log("whitelisted proposal hash:");
  console.log(proposal.hash.toHex());

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  decoder.printTree(decoder.transformCall(extrinsic.toHuman()));
});
