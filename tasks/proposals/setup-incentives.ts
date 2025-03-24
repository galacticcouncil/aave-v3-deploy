import { task } from "hardhat/config";
import { exit } from "process";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { ZERO_ADDRESS } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { addTransaction, getBatch } from "../../helpers/transaction-batch";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { getEmissionManager } from "../../helpers/contract-getters";
import { TransferStrategy } from "./../../helpers/types";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import { getBlockTimestamp } from "../../helpers/utilities/tx";
import chalk from "chalk";

task(`setup-incentives`, `Updates incentives program or starts new one if incentives doesn't exists.`).setAction(async function (_, hre) {
  const network = FORK ? FORK : (hre.network.name as eNetwork);

  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const chainlinkConf = poolConfig.ChainlinkAggregator[network];
  const incentivesConf = poolConfig.IncentivesConfig[network];
  const em = await getEmissionManager();

  if (!chainlinkConf) {
    console.log(chalk.red(`chainlink configuration for ${network} network not found`));
    exit(1);
  }

  const incentivizedTkns = Object.keys(incentivesConf);
  const assetsConf = [];
  const transferStrat = await getPotRewardsStrategy();
  var emissionAdmin;

  for (let i = 0; i < incentivizedTkns.length; i++ ) {
    const incTkn = incentivizedTkns[i];
    const cfg = incentivesConf[incTkn];

    if (!cfg.asset || cfg.asset == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid incentive config`));
      exit(1);
    }

    if (cfg.transferStrategy != TransferStrategy.PotRewardsStrategy) {
      console.log(chalk.red(`${incTkn}: invalid transfer strategy. Only PotRewardsStrategy is supported`));
      exit(1);
    }

    if (!cfg.reward || cfg.reward == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid reward value: ${cfg.reward}`));
      exit(1);
    }
    const emAdmin = await em.getEmissionAdmin(cfg.reward);
    if (!emAdmin || emAdmin.toLowerCase() != cfg.emissionAdmin.toLowerCase() || emAdmin == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid emission admin for reward asset: ${cfg.reward}. onchain admin: ${emAdmin}, configured admin: ${cfg.emissionAdmin}`));
      exit(1);
    }

    if (!emissionAdmin) {
      emissionAdmin = emAdmin;
    }

    if (emissionAdmin.toLowerCase() != emAdmin.toLowerCase()) {
      console.log(chalk.red(`${incTkn}: all incentives doesn't have same emission admin. Transactions can't be batched`));
      exit(1);
    }

    const time = await getBlockTimestamp();
    assetsConf.push({
      emissionPerSecond: cfg.emissionPerSecond,
      distributionEnd: time + cfg.duration,
      asset: cfg.asset,
      reward: cfg.reward,
      transferStrategy: transferStrat.address,
      rewardOracle: cfg.rewardOracle,
      totalSupply: "0",
    })
  }

  if (assetsConf.length == 0) {
    console.log("nothing to setup/update")
    return;
  }

  let tx = await em.populateTransaction.configureAssets(assetsConf, { gasLimit: 1000000 });
  const { preimages, whitelist, proposal, whitelistedCall } =
     await generateProposal([tx], emissionAdmin, [], true);

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
