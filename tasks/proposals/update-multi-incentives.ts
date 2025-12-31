// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
  getApi,
  evmAddress,
  padAddress,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`update-multi-incentives`, `Update incentives for multiple reserves`)
  .addVariadicPositionalParam(
    "reserves",
    "Reserve names to update incentives for (e.g., 3-POOL 2-POOL-GDOT)"
  )
  .setAction(async function ({ reserves }, hre) {
    const admin = await requirePoolAdmin(hre);

    // Clear any existing batch transactions
    clearBatch();

    // Process each reserve and add to batch
    for (const reserve of reserves) {
      console.log(`\nProcessing reserve: ${reserve}`);
      await hre.run("review-incentive", {
        batch: true,
        reserve: reserve,
      });
    }

    // Get all batched transactions
    const batchedTxs = getBatch();

    if (batchedTxs.length === 0) {
      console.log("\nNo changes detected for any reserves.");
      return;
    }

    console.log(`\nTotal batched transactions: ${batchedTxs.length}`);

    // Convert admin EVM address to proper format (padded, then back to EVM)
    const paddedAdmin = padAddress(admin);
    const adminEvmAddress = await evmAddress(paddedAdmin);

    // Convert each transaction to aaveManagerCall
    const aaveManagerCalls = await Promise.all(
      batchedTxs.map((tx) =>
        aaveManagerCall({
          from: adminEvmAddress,
          to: tx.to,
          data: tx.data,
          gasLimit: tx.gasLimit?.toString() || "300000",
          gasPrice: tx.maxFeePerGas?.toString() || "600000000",
        })
      )
    );

    // Generate proposal with all batched transactions using V2
    const proposal = await generateProposalV2(aaveManagerCalls);

    const decoder = new ProposalDecoder(hre);
    await decoder.init();

    console.log("\n=== Proposal Hex ===");
    console.log(proposal.toHex());

    console.log("\n=== Decoded Proposal ===");
    decoder.printTree(decoder.transformCall(proposal.toHuman()));

    console.log("\n=== Proposal Hash ===");
    console.log(proposal.hash.toHex());
  });
