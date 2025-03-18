import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { addTransaction, getBatch } from "../../helpers/transaction-batch";
import { ZERO_ADDRESS } from "./../../helpers/constants";

import { getEmissionManager, getIncentivesV2  } from "../../helpers/contract-getters";
import { getAddress } from "ethers/lib/utils";


import {
  getPoolAddressesProvider,
} from "../../helpers/contract-getters";
import { POOL_ADDRESSES_PROVIDER_ID } from "../../helpers/deploy-ids";
import { getAddressFromJson, getBlockTimestamp } from "../../helpers/utilities/tx";
import { getAaveProtocolDataProvider, getPullRewardsStrategy } from "../../helpers/contract-getters";
import { FORK } from "../../helpers/hardhat-config-helpers";
import {
  INCENTIVES_PROXY_ID,
} from "../../helpers/deploy-ids";

import { exit } from "process";
task(`setup-incentives`, `Updates incentives program or starts new one if incentives doesn't exists.`).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);
  const incentives = await getIncentivesV2();


  const time = await getBlockTimestamp();
  
  const { address: rewardsProxyAddress } = await hre.deployments.get(
    INCENTIVES_PROXY_ID
  );

  const { deployer, incentivesRewardsVault, incentivesEmissionManager } = await hre.getNamedAccounts();

  const pullRewStrategy = await getPullRewardsStrategy();

  const emissionManager = await getEmissionManager()
  const emissionAdmin = await emissionManager.getEmissionAdmin("0x0000000000000000000000000000000100000005")

  //2 lines bellow worked
  let tx = await emissionManager.populateTransaction.setEmissionAdmin("0x0000000000000000000000000000000100000005", admin, {gasLimit: 100000});
  const emissionOwner = await emissionManager.owner(); //signed as this account
  const fromAcc = emissionOwner;


  //let tx = await emissionManager.populateTransaction.configureAssets([{
  //  emissionPerSecond: ethers.utils.parseEther("0.1"),
  //  totalSupply: "1000_000_000_000_000_000_000".replaceAll("_", ""),
  //  distributionEnd: time + + 1000 * 60 * 60,
  //  asset: "0x02639ec01313c8775Fae74F2dad1118c8A8a86dA", //aDot
  //  reward: "0x0000000000000000000000000000000100000005", //Dot
  //  transferStrategy: pullRewStrategy.address,
  //  rewardOracle: "0xfbca0a6dc5b74c042df23025d99ef0f1fcac6702",
  //}], { gasLimit: 1000000 });
  //const fromAcc = emissionAdmin;
  if (emissionAdmin == ZERO_ADDRESS) {
    throw new Error("emission admin is not set");
  }
  //TODO: check RewardsStrategy was deployed


  const { preimages, whitelist, proposal, whitelistedCall } =
     await generateProposal([tx], fromAcc, [], true);

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
