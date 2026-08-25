// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  FORK,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(
  `update-oracles-and-caps`,
  `Update oracles, PRIME caps, and HOLLAR mint limit`
).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  // Update oracle prices
  await hre.run("set-oracle-price", {
    oracle: "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307", // PRIME/USD
    price: "102841386",
  });

  await hre.run("set-oracle-price", {
    oracle: "0x5B29bceaCBD1c37FD4A2c32a052b63813ed0D4b8", // jitoSOL/SOL
    price: "126960557",
  });

  await hre.run("set-oracle-price", {
    oracle: "0x11c1E47AaEcdc47dba8b9B9419b05903e53F3b4f", // wstETH/USD
    price: "123081881",
  });

  // Update PRIME supply cap (10M -> 15M) and debt ceiling ($8M -> $12M)
  await hre.run("review-supply-caps", {
    fix: true,
    batch: true,
    checkOnly: "PRIME",
  });

  await hre.run("review-debt-ceiling", {
    fix: true,
    batch: true,
    checkOnly: "PRIME",
  });

  // Increase HOLLAR mint limit from 7M to 12M
  // GhoToken.setFacilitatorBucketCapacity(aToken facilitator, 12M)
  const HOLLAR = "0x531a654d1696ed52e7275a8cede955e82620f99a";
  const aTokenFacilitator = "0x8c0f3b9602374198974d2b2679d14a386f5b108e";
  const gho = await hre.ethers.getContractAt(
    ["function setFacilitatorBucketCapacity(address, uint128)"],
    HOLLAR
  );
  addTransaction(
    await gho.populateTransaction.setFacilitatorBucketCapacity(
      aTokenFacilitator,
      hre.ethers.utils.parseUnits("12000000", 18), // 12M with 18 decimals
      { gasLimit: 200000 }
    )
  );

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
