
import { task } from "hardhat/config";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import {
  INCENTIVES_PROXY_ID,
  INCENTIVES_POT_REWARDS_STRATEGY_ID,
} from "../../helpers/deploy-ids";
  

task(
  `deploy-PotRewardsTransferStrategy`,
  `Deploys the ./contracts/PotRewardsTransferStrategy contract`
).setAction(async (_, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }

  const { deployer, incentivesRewardsVault, incentivesEmissionManager } = await hre.getNamedAccounts();
  const { address: rewardsProxyAddress } = await hre.deployments.get(
    INCENTIVES_PROXY_ID
  );

  console.log(`\n- PotRewardsTransferStrategy deployment`);
  const artifact = await hre.deployments.deploy(INCENTIVES_POT_REWARDS_STRATEGY_ID, {
    from: deployer,
    args:[rewardsProxyAddress, incentivesEmissionManager]
  });

  console.log("PotRewardsTransferStrategy deployed at:", artifact.address);
  console.log(`\tFinished PotRewardsTransferStrategy deployment`);
});
