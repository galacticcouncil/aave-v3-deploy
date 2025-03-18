import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { exit } from "process";
import { MARKET_NAME } from "../../helpers/env";
import { ZERO_ADDRESS } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { getEmissionManager } from "../../helpers/contract-getters";
import chalk from "chalk";
import { addTransaction } from "../../helpers/transaction-batch";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`setup-emission-admins`, `Setup emission admin for`)
  .setAction(async function (_, hre) {
  const network = FORK ? FORK : (hre.network.name as eNetwork);

  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const incentivesConf = poolConfig.IncentivesConfig[network];
  const em = await getEmissionManager();

  if (!incentivesConf) {
    console.log(chalk.yellow(`no incentives configuration found for config.IncentivesConfig.${network}`));
    exit(0);
  }

  const incentivizedTkns = Object.keys(incentivesConf);
  for (let i = 0; i < incentivizedTkns.length; i++ ) {
    const incTkn = incentivizedTkns[i];
    const cfg = incentivesConf[incTkn];

    if (!cfg.asset || cfg.asset == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid incentive config`));
      exit(1);
    }

    if (!cfg.reward || cfg.reward == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid reward value: ${cfg.reward}`));
      exit(1);
    }

    if (!cfg.emissionAdmin || cfg.emissionAdmin == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid emission admin: ${cfg.emissionAdmin}`));
      exit(1);
    }

    if (cfg.emissionAdmin == await em.getEmissionAdmin(cfg.reward)) {
      console.log(`${incTkn}: ${cfg.reward}'s admin already set to: ${cfg.emissionAdmin}`);
      continue;
    }
   
    const tx = await em.populateTransaction.setEmissionAdmin(cfg.reward, cfg.emissionAdmin, {gasLimit: 100000});
    addTransaction(tx);
  };

  const txs = getBatch();
  if (txs.length == 0) {
    console.log("nothing to setup/update")
    return;
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
