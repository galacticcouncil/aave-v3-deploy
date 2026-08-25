import { task } from "hardhat/config";
import { ORACLES_AGGREGATOR_ID } from "../../helpers/deploy-ids";
import { ZERO_ADDRESS, POOL_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { exit } from "process";
import chalk from "chalk";

task(
  `deploy-OraclesAggregator`,
  `Deploys the ./contracts/OraclesAggregator contract`
)
  .addParam("oracle", "oracle aggregator name")
  .setAction(async ({ oracle }: { oracle: string }, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const network = FORK ? FORK : (hre.network.name as eNetwork);
    const admin = POOL_ADMIN[network];

    const poolConfig = await loadPoolConfig(MARKET_NAME);
    const aggregatorConf = poolConfig.OraclesAggregator[network]?.[oracle];
    if (!aggregatorConf) {
      console.log(
        chalk.red(`'OraclesAggregator.${network}.${oracle}' deosn't exists`)
      );
      exit(1);
    }

    if (
      !aggregatorConf.srcAssetToX ||
      aggregatorConf.srcAssetToX == ZERO_ADDRESS
    ) {
      console.log(
        chalk.red(
          `'OraclesAggregator.${network}.${oracle}.srcAssetToX' is not valid`
        )
      );
      exit(1);
    }

    if (
      !aggregatorConf.destAssetToX ||
      aggregatorConf.destAssetToX == ZERO_ADDRESS
    ) {
      console.log(
        chalk.red(
          `'OraclesAggregator.${network}.${oracle}.destAssetToX' is not valid`
        )
      );
      exit(1);
    }

    console.log(`\n- OraclesAggregator deployment`);
    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(
      `${oracle}-${ORACLES_AGGREGATOR_ID}`,
      {
        from: deployer,
        contract: ORACLES_AGGREGATOR_ID,
        args: [aggregatorConf.srcAssetToX, aggregatorConf.destAssetToX],
      }
    );

    console.log("OraclesAggregator deployed at:", artifact.address);
    console.log(`\tFinished OraclesAggregator deployment`);
  });
