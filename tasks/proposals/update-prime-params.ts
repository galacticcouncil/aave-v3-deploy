// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import {
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  FORK,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(
  `update-prime-params`,
  `Increase PRIME supply cap to 10M, debt ceiling to $8M, and update oracle to 1.0268`
).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  // Update PRIME oracle price to 1.0268
  await hre.run("set-oracle-price", {
    oracle: "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307", // PRIME/USD
    price: "102680000",
  });

  // Update PRIME supply cap from 5M to 10M
  await hre.run("review-supply-caps", {
    fix: true,
    batch: true,
    checkOnly: "PRIME",
  });

  // Update PRIME debt ceiling from $4M to $8M
  await hre.run("review-debt-ceiling", {
    fix: true,
    batch: true,
    checkOnly: "PRIME",
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  const proposal = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("proposal preimage:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("hash:");
  console.log(proposal.hash.toHex());
});
