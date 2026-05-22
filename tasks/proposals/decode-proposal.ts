// @ts-nocheck
import { getApi } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`decode-proposal`, `Decode an encoded proposal and print the decoded tree`)
  .addParam("hex", "The hex-encoded proposal to decode")
  .setAction(async function ({ hex }, hre) {
    const api = await getApi();

    const decoded = api.createType("Call", hex);

    const decoder = new ProposalDecoder(hre);
    await decoder.init();

    console.log("\n=== Decoded Proposal ===\n");
    decoder.printTree(decoder.transformCall(decoded.toHuman()));
  });