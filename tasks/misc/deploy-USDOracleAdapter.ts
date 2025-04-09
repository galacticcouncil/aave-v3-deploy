import { task } from "hardhat/config";
import {
  USD_ORACLE_ADAPTER_ID,
} from "../../helpers/deploy-ids";
import { ZERO_ADDRESS, POOL_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { exit } from "process";
import chalk from "chalk";

task(
  `deploy-USDOracleAdapter`,
  `Deploys the ./contracts/USDOracleAdapter contract`
)
  .addParam("oracle", "oracle adapter name")
  .setAction(async ({
    oracle
  }: { oracle: string }, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }
  const network = FORK ? FORK : (hre.network.name as eNetwork);
  const admin = POOL_ADMIN[network];

  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const adapterConf = poolConfig.USDOracleAdapter[network]?.[oracle];
  if (!adapterConf) {
    console.log(
      chalk.red(
        `'USDOracleAdapter.${network}.${oracle}' deosn't exists`
      )
    );
    exit(1)
  }
  
  if (!adapterConf.assetToX || adapterConf.assetToX == ZERO_ADDRESS) {
    console.log(
      chalk.red(
        `'USDOracleAdapter.${network}.${oracle}.assetToX' is not valid`
      )
    );
    exit(1)
  }
  
      if (!adapterConf.xToUSD || adapterConf.xToUSD == ZERO_ADDRESS) {
    console.log(
      chalk.red(
        `'USDOracleAdapter.${network}.${oracle}.xToUSD' is not valid`
      )
    );
    exit(1)
  }

  console.log(`\n- USDOracleAdapter deployment`);
  const { deployer } = await hre.getNamedAccounts();
  const artifact = await hre.deployments.deploy(`${oracle}-${USD_ORACLE_ADAPTER_ID}`, {
    from: deployer,
    contract: USD_ORACLE_ADAPTER_ID,
    args: [
      adapterConf.assetToX,
      adapterConf.xToUSD,
    ],
  });

  console.log("USDOracleAdapter deployed at:", artifact.address);
  console.log(`\tFinished USDOracleAdapter deployment`);
});
