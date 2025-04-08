import { task } from "hardhat/config";
import { getUSDOracleAdapter } from "../../helpers/contract-getters";
import {
  INCENTIVES_PROXY_ID,
  USD_ORACLE_ADAPTER_ID,
} from "../../helpers/deploy-ids";
import { ZERO_ADDRESS, POOL_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import chalk from "chalk";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";

task(
  `deploy-USDOracleAdapter`,
  `Deploys the ./contracts/USDOracleAdapter contract`
).setAction(async (_, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }
  const network = FORK ? FORK : (hre.network.name as eNetwork);
  const admin = POOL_ADMIN[network];

  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const chainlinkConf = poolConfig.ChainlinkAggregator[network];
  if (!chainlinkConf) {
    console.log(chalk.red(`'${network}': chainlink configuration not found`));
    exit(1);
  }

  const usdOracleAddr = chainlinkConf["DOT"];
  if (!usdOracleAddr || usdOracleAddr == ZERO_ADDRESS) {
    console.log(
      chalk.red(
        `'${network}: oracle wasn't found in ChainlinkAggregator or is not valid`
      )
    );
    exit(1);
  }

  const decimals = 10;

  console.log(`\n- USDOracleAdapter deployment`);
  const { deployer } = await hre.getNamedAccounts();
  const artifact = await hre.deployments.deploy(USD_ORACLE_ADAPTER_ID, {
    from: deployer,
    args: [
      "0x000001006f6d6e69706f6f6c0000000000000005",
      usdOracleAddr,
      decimals,
    ],
  });

  console.log("PotRewardsTransferStrategy deployed at:", artifact.address);
  console.log(`\tFinished PotRewardsTransferStrategy deployment`);
});
