import { HardhatRuntimeEnvironment } from "hardhat/types";
import {
  ConfigNames,
  getChainlinkOracles,
  getReserveAddresses,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  configureReservesByHelper,
  getPairsTokenAggregator,
  initReservesByHelper,
} from "../../helpers/init-helpers";
import { ORACLE_ID } from "../../helpers/deploy-ids";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction } from "../../helpers/transaction-batch";
import { exit } from "process";
import chalk from "chalk";
import { FORK, ZERO_ADDRESS } from "../../helpers";

task(`set-reserve-oracle`, ``)
  .addParam("symbol", "symbol of the reserve")
  .addFlag("batch", "Batch transactions")
  .setAction(
    async (
      { symbol, batch = false }: { symbol: string; batch: boolean },
      hre: HardhatRuntimeEnvironment
    ) => {
      const { deployments, getNamedAccounts } = hre;
      const networkId = FORK ? FORK : hre.network.name;
      const { deployer } = await getNamedAccounts();

      const poolConfig = await loadPoolConfig(MARKET_NAME as ConfigNames);

      const reservesAddresses = await getReserveAddresses(
        poolConfig,
        networkId
      );

      const reserveAddress = reservesAddresses[symbol.toUpperCase()];
      if (!reserveAddress) {
        console.error(chalk.red(`Reserve ${symbol} not found`));
        exit(1);
      }

      const reserve = { [symbol.toUpperCase()]: reserveAddress };
      const chainlinkAggregators = await getChainlinkOracles(
        poolConfig,
        networkId
      );

      const [asset, source] = getPairsTokenAggregator(
        reserve,
        chainlinkAggregators
      );
      if (!source || source[0].toUpperCase() == ZERO_ADDRESS.toUpperCase()) {
        console.error(
          chalk.red(
            `Chainlink oracle for ${symbol} not found or is not valid, oracle: ${source}`
          )
        );
        exit(1);
      }

      const { abi, address } = await deployments.get(ORACLE_ID);
      const oracle = (await hre.ethers.getContractAt(abi, address)).connect(
        await hre.ethers.getSigner(deployer)
      );
      if (batch) {
        const tx = await oracle.populateTransaction.setAssetSources(
          asset,
          source
        );
        addTransaction(tx);
      } else {
        await oracle.setAssetSources(asset, source);
      }
    }
  );
