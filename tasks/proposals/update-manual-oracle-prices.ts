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
    oracle: "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307", // PRIME/USD
    price: "103220000",
  });

  await hre.run("set-oracle-price", {
    oracle: "0x5B29bceaCBD1c37FD4A2c32a052b63813ed0D4b8", // jitoSOL/SOL
    price: "127468640",
  });

  await hre.run("set-oracle-price", {
    oracle: "0x11c1E47AaEcdc47dba8b9B9419b05903e53F3b4f", // wstETH/ETH
    price: "123246839",
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
