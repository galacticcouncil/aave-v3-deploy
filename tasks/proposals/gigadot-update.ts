// @ts-nocheck
import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  generateProposal,
  getApi,
  location,
  generateProposalV2,
  dispatchAs,
  rootEvmCall,
  padAddress,
  account,
} from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  ZERO_ADDRESS,
} from "../../helpers";
import { network } from "hardhat";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { exit } from "process";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import chalk from "chalk";

task(`gigadot-update`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolConfigurator = (await getPoolConfiguratorProxy()).connect(signer);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  const hydrationTx = (await getApi()).tx;

  const txs = [];

  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  console.log("review and update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("update DOT emode");
  await hre.run("review-e-mode", {
    name: "DotEMode",
    fix: true,
    batch: true,
  });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("add GDOT to DOT emode");
  {
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(
      await getReserveAddress(config, "GDOT"),
      config.EModes["DotEMode"].id
    );
    addTransaction(tx);
  }
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("review and udpate incentives");
  await hre.run("review-emission-admin", { batch: true, reserve: "GDOT" });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  await hre.run("review-incentive", {
    batch: true,
    reserve: "GDOT",
  });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
