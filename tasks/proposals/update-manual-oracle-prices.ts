// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
  getApi,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import ProposalDecoder from "../../helpers/proposal-decoder";
import chalk from "chalk";
import { exit } from "process";
import {
  FORK,
  POOL_ADMIN,
  getPoolAddressesProvider,
  getACLManager,
} from "../../helpers";

task(`update-manual-oracle-prices`).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  await hre.run("set-oracle-price", {
    oracle: "0x11c1E47AaEcdc47dba8b9B9419b05903e53F3b4f", // wstETH/USD
    price: "122788508",
  });

  await hre.run("set-oracle-price", {
    oracle: "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307", // prime/USD
    price: "102124771",
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
  console.log("hash:");
  console.log(preimage.hash.toHex());
});
