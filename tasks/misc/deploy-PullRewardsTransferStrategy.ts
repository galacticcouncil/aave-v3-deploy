
import { task } from "hardhat/config";
import { getAaveProtocolDataProvider, getPullRewardsStrategy } from "../../helpers/contract-getters";
import {
  INCENTIVES_PULL_REWARDS_STRATEGY_ID,
  INCENTIVES_PROXY_ID,
} from "../../helpers/deploy-ids";
  

task(
  `deploy-PullRewardsTransferStrategy`,
  `Deploys the PullRewardsTransferStrategy contract`
).setAction(async (_, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }

  const { deployer, incentivesRewardsVault, incentivesEmissionManager } = await hre.getNamedAccounts();
  const { address: rewardsProxyAddress } = await hre.deployments.get(
    INCENTIVES_PROXY_ID
  );

  console.log(`\n- PullRewardsTransferStrategy deployment`);
  const artifact = await hre.deployments.deploy(INCENTIVES_PULL_REWARDS_STRATEGY_ID, {
    from: deployer,
    args:[rewardsProxyAddress, incentivesEmissionManager, incentivesRewardsVault]
  });

  console.log("PullRewardsTransferStrategy deployed at:", artifact.address);
  console.log(`\tFinished PullRewardsTransferStrategy deployment`);
});
