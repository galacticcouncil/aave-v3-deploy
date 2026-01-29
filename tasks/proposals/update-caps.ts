// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-caps`, ``)
  .addFlag("whitelisted", "Generate a whitelisted proposal")
  .setAction(async function ({ whitelisted }, hre) {
    const admin = await requirePoolAdmin(hre);

    await hre.run("review-supply-caps", { fix: true, batch: true });
    await hre.run("review-borrow-caps", { fix: true, batch: true });

    const txs = await Promise.all(
      getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
    );
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    let prop = await generateProposalV2(txs, whitelisted);
    if (whitelisted) {
      const { whitelistedCall, proposal } = prop;
      console.log("submit preimages:");
      console.log(whitelistedCall.toHex());
      console.log("whitelist image:");
      console.log(proposal.toHex());
      decoder.printTree(decoder.transformCall(proposal.toHuman()));
    } else {
      console.log("submit preimages:");
      console.log(prop.toHex());
      decoder.printTree(decoder.transformCall(prop.toHuman()));
    }
  });
