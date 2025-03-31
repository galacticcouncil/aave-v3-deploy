
import { task } from "hardhat/config";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import {
  INCENTIVES_PROXY_ID,
  INCENTIVES_POT_REWARDS_STRATEGY_ID,
} from "../../helpers/deploy-ids";
import { ZERO_ADDRESS, POOL_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
  

task(
  `deploy-PotRewardsTransferStrategy`,
  `Deploys the ./contracts/PotRewardsTransferStrategy contract`
).setAction(async (_, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }
  const network = FORK ? FORK : (hre.network.name as eNetwork);
  const admin = POOL_ADMIN[network];

  if (!admin || admin == ZERO_ADDRESS ) {
    console.log(chalk.red(`POOL_ADMIN[${network}] is zero address`));
    exit(1);
  }

  const { deployer, } = await hre.getNamedAccounts();
  const { address: rewardsProxyAddress } = await hre.deployments.get(
    INCENTIVES_PROXY_ID
  );

  console.log(`\n- PotRewardsTransferStrategy deployment`);
  const artifact = await hre.deployments.deploy(INCENTIVES_POT_REWARDS_STRATEGY_ID, {
    from: deployer,
    args:[rewardsProxyAddress, admin]
  });

  console.log("PotRewardsTransferStrategy deployed at:", artifact.address);
  console.log(`\tFinished PotRewardsTransferStrategy deployment`);
});
