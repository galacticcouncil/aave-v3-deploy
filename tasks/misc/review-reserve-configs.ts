import { eNetwork } from "./../../helpers/types";
import {
  POOL_CONFIGURATOR_PROXY_ID,
  POOL_ADDRESSES_PROVIDER_ID,
} from "../../helpers/deploy-ids";
import { getAddressFromJson, waitForTx } from "../../helpers/utilities/tx";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import {
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  getUiPoolDataProvider,
} from "../../helpers/contract-getters";
import { task } from "hardhat/config";
import { MARKET_NAME } from "../../helpers/env";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { diff, formatters } from "jsondiffpatch";
import chalk from "chalk";
import { addTransaction } from "../../helpers/transaction-batch";

task(`review-reserve-configs`, ``)
  .addFlag("fix")
  .addFlag("batch")
  .addOptionalParam("only", "only check those assets")
  .setAction(
    async (
      { only, fix, batch }: { only: string[]; fix: boolean; batch: boolean },
      hre
    ) => {
      const { poolAdmin } = await hre.getNamedAccounts();
      const network = FORK ? FORK : (hre.network.name as eNetwork);
      const poolConfigurator = (
        await getPoolConfiguratorProxy(
          await getAddressFromJson(network, POOL_CONFIGURATOR_PROXY_ID)
        )
      ).connect(await hre.ethers.getSigner(poolAdmin));
      const poolAddressesProvider = await getPoolAddressesProvider(
        await getAddressFromJson(network, POOL_ADDRESSES_PROVIDER_ID)
      );
      const poolConfig = await loadPoolConfig(MARKET_NAME);
      const view = await getUiPoolDataProvider(
        (
          await hre.deployments.get("UiPoolDataProviderV3")
        ).address
      );
      const onChainReserves = await view.getReservesData(
        poolAddressesProvider.address
      );

      for (let reserve of onChainReserves[0]) {
        const symbol = reserve.symbol.toUpperCase();
        if (only && !only.includes(symbol)) {
          continue;
        }
        console.log("checking", symbol);
        const reserveConfig = poolConfig.ReservesConfig[symbol];
        if (!reserveConfig) {
          console.log("reserve config missing for " + symbol);
          continue;
        }

        const current = {
          baseLTVAsCollateral: reserve.baseLTVasCollateral.toString(),
          liquidationThreshold: reserve.reserveLiquidationThreshold.toString(),
          liquidationBonus: reserve.reserveLiquidationBonus.toString(),
        };

        const desired = {
          baseLTVAsCollateral: reserveConfig.baseLTVAsCollateral,
          liquidationThreshold: reserveConfig.liquidationThreshold,
          liquidationBonus: reserveConfig.liquidationBonus,
        };

        const delta = diff(current, desired);
        if (delta) {
          console.log(
            `- Found ${chalk.red(
              "differences"
            )} at on chain reserve config of ${symbol}`
          );
          console.log(
            chalk.red("Current config", "=>", chalk.green("Desired config"))
          );
          console.log(formatters.console.format(delta, desired));

          if (fix) {
            console.log("fixing...");
            const tx =
              await poolConfigurator.populateTransaction.configureReserveAsCollateral(
                reserve.underlyingAsset,
                reserveConfig.baseLTVAsCollateral,
                reserveConfig.liquidationThreshold,
                reserveConfig.liquidationBonus
              );
            if (batch) {
              addTransaction(tx);
            } else {
              const receipt = await waitForTx(
                await poolConfigurator.signer.sendTransaction(tx)
              );
              console.log("fixed", receipt?.transactionHash);
            }
          }
        }
      }
    }
  );
