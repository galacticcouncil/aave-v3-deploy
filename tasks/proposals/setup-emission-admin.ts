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
import { getAddress } from "ethers/lib/utils";

task(`setup-emission-admins`, `Setup emission admin for`).setAction(async function (_, hre) {
  const network = FORK ? FORK : (hre.network.name as eNetwork);

  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const chainlinkConf = poolConfig.ChainlinkAggregator[network];
  const emAdminsConf = poolConfig.IncentivesConfig.rewards[network];
  const em = await getEmissionManager();

  if (!emAdminsConf) {
    console.log(chalk.yellow(`no emission admin configuration found in config.IncentivesConfig.rewards${network}`));
    exit(0);
  }

  const tkns = Object.keys(emAdminsConf);
  for (let i = 0; i < tkns.length; i++ ) {
    const tkn = tkns[i];
    const admin = emAdminsConf[tkn];

    if (admin == ZERO_ADDRESS) {
      console.log(chalk.red(`emission admin for ${tkn} can't be zero address`));
      exit(1);
    }

    if (admin == await em.getEmissionAdmin(tkn)) {
      console.log(`${tkn} admin already set to: ${admin}`);
      continue;
    }
   
    const tknAddr = chainlinkConf[tkn];
    if (!tknAddr || tknAddr == ZERO_ADDRESS) {
      console.log(chalk.red(`emission admin for ${tkn} can't be zero address`));
      exit(1);
    }
    console.log("tkn addr: ", tknAddr);
    const tx = await em.populateTransaction.setEmissionAdmin(tkn, admin, {gasLimit: 100000});
    addTransaction(tx)
  };

  const txs = getBatch();
  console.log(tx);
  if (txs.length == 0) {
    console.log("nothing to set/update")
    return;
  }

  const signer = await em.owner();
  console.log(signer);
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
