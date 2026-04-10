// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import {
  getBatch,
  clearBatch,
  addTransaction,
} from "../../helpers/transaction-batch";
import {
  ConfigNames,
  getOracleByAsset,
  getPoolConfiguratorProxy,
  getReserveAddress,
  loadPoolConfig,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { MARKET_NAME } from "../../helpers/env";

task(`halvening`, ``).setAction(async function (_, hre) {
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolConfigurator = (await getPoolConfiguratorProxy()).connect(signer);
  const txs = [];

  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
    only: "DOT",
  });

  const oracle = await getOracleByAsset(config, "PRIME");

  await hre.run("set-oracle-price", {
    oracle,
    price: "102415740",
  });

  for (const el of getBatch()) {
    el.from = POOL_ADMIN[hre.network.name];
    txs.push(await aaveManagerCall(el));
  }
  clearBatch();

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
