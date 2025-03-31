import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { exit } from "process";
import { MARKET_NAME } from "../../helpers/env";
import { ZERO_ADDRESS, POOL_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { getEmissionManager } from "../../helpers/contract-getters";
import chalk from "chalk";
import { addTransaction } from "../../helpers/transaction-batch";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`review-emission-admin`, ``)
  .addFlag("batch")
  .addParam("reserve", "reserve's incentive config")
  .setAction(
    async (
      { batch, reserve }: { batch: boolean, reserve: string },
      hre
  ) => {
  const network = FORK ? FORK : (hre.network.name as eNetwork);
  const admin = POOL_ADMIN[network];
  if (!admin || admin == ZERO_ADDRESS ) {
    console.log(chalk.red(`POOL_ADMIN[${network}] is zero address`));
    exit(1);
  }
 
  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const incentiveConf = poolConfig.IncentivesConfig[network]?.[reserve];
  const em = await getEmissionManager();

  if (!incentiveConf || incentiveConf.length == 0) {
    console.log(chalk.red(`'${network}.${reserve}': incentive config not found or is not valid`));
    exit(1);
  }

  console.log(`'${network}.${reserve}': reviewing emission admin`) 

  for (let i = 0; i < incentiveConf.length; i++) {
    const emAdmin = incentiveConf[i].emissionAdmin;
    const reward = incentiveConf[i].reward;
   
    if (!reward || reward == ZERO_ADDRESS) {
      console.log(chalk.red(`'${network}.${reserve}[${i}]': reward token '${reward}' is not valid`));
      exit(1);
    }

    if (!emAdmin || emAdmin == ZERO_ADDRESS) {
      console.log(chalk.red(`'${network}.${reserve}[${i}]': emission admin '${emAdmin}' is not valid`));
      exit(1);
    }

    if (emAdmin.toLowerCase() != admin.toLowerCase()) {
      console.log(chalk.red(`'${network}.${reserve}[${i}]': emission admin is not pool admin`));
      exit(1);
    }

    if (emAdmin == await em.getEmissionAdmin(reward)) {
      continue
    }

    const tx = await em.populateTransaction.setEmissionAdmin(reward, emAdmin, {gasLimit: 100000});
    addTransaction(tx);
  }

  if (batch) {
    return
  }

  const txs = getBatch();
  if (txs.length == 0) {
    console.log(chalk.green(`'${network}.${reserve}': no emission admin to update`));
    return
  }

  const signer = await em.owner();
  if (signer == ZERO_ADDRESS) {
    console.log(chalk.red(`emissionManager's owner can't be zero address`));
    exit(1);
  }

  const { preimages, whitelist, proposal, whitelistedCall } = await generateProposal(txs, signer, [], true);

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
