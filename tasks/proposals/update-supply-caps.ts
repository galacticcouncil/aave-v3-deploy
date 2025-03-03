import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-supply-caps`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  const { preimages, whitelist, proposal, whitelistedCall } =
    await generateProposal(getBatch(), admin, [], true);

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimages.toHex());
  decoder.printTree(decoder.transformCall(preimages.toHuman()));
  console.log("whitelisted call hash:", whitelistedCall.hash.toHex());
  console.log(whitelistedCall.toHex());
  decoder.printTree(decoder.transformCall(whitelistedCall.toHuman()));
  console.log("whitelist call hash:", whitelistedCall.hash.toHex());
  console.log(whitelist.toHex());
  decoder.printTree(decoder.transformCall(whitelist.toHuman()));
  console.log("whitelisted proposal:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("whitelisted proposal hash:");
  console.log(proposal.hash.toHex());
});
