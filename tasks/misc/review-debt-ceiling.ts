import { eNetwork } from "../../helpers/types";
import {
  POOL_CONFIGURATOR_PROXY_ID,
  POOL_DATA_PROVIDER,
} from "../../helpers/deploy-ids";
import { getAddressFromJson, waitForTx } from "../../helpers/utilities/tx";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import {
  getAaveProtocolDataProvider,
  getPoolConfiguratorProxy,
} from "../../helpers/contract-getters";
import { task } from "hardhat/config";
import { MARKET_NAME } from "../../helpers/env";
import { FORK } from "../../helpers/hardhat-config-helpers";
import chalk from "chalk";
import { exit } from "process";
import { addTransaction } from "../../helpers/transaction-batch";
import { BigNumber } from "ethers";

task(`review-debt-ceiling`, `Review and fix debt ceiling configuration`)
  .addFlag("fix")
  .addFlag("batch")
  .addOptionalParam("checkOnly")
  .setAction(
    async (
      {
        fix,
        checkOnly,
        batch,
      }: { fix: boolean; checkOnly: string; batch: boolean },
      hre
    ) => {
      const network = FORK ? FORK : (hre.network.name as eNetwork);
      const { poolAdmin } = await hre.getNamedAccounts();
      const checkOnlyReserves: string[] = checkOnly ? checkOnly.split(",") : [];

      const dataProvider = await getAaveProtocolDataProvider(
        await getAddressFromJson(network, POOL_DATA_PROVIDER)
      );
      const poolConfigurator = (
        await getPoolConfiguratorProxy(
          await getAddressFromJson(network, POOL_CONFIGURATOR_PROXY_ID)
        )
      ).connect(await hre.ethers.getSigner(poolAdmin));

      const poolConfig = await loadPoolConfig(MARKET_NAME);
      const reserveAssets = poolConfig.ReserveAssets?.[network];

      if (!reserveAssets) {
        console.log("Exiting due missing ReserveAssets");
        exit(2);
      }

      const reservesToCheck = checkOnlyReserves.length
        ? Object.keys(reserveAssets).filter((symbol) =>
            checkOnlyReserves.includes(symbol)
          )
        : Object.keys(reserveAssets);

      for (const symbol of reservesToCheck) {
        const tokenAddress = reserveAssets[symbol];
        const normalizedSymbol = symbol.toUpperCase();

        if (!poolConfig.ReservesConfig[normalizedSymbol]) {
          console.log(`- Skipping ${symbol} (not found in ReservesConfig)`);
          continue;
        }

        console.log(
          "- Checking reserve",
          symbol,
          `, normalized symbol`,
          normalizedSymbol
        );

        const expectedDebtCeiling = BigNumber.from(
          poolConfig.ReservesConfig[normalizedSymbol].debtCeiling
        );
        const onChainDebtCeiling = await dataProvider.getDebtCeiling(
          tokenAddress
        );

        const delta = !expectedDebtCeiling.eq(onChainDebtCeiling);

        if (delta) {
          console.log(
            "- Found differences in debt ceiling for",
            normalizedSymbol
          );
          console.log(
            "  - Expected:",
            (Number(expectedDebtCeiling) / 100).toLocaleString(undefined, {
              minimumFractionDigits: 2,
            })
          );
          console.log(
            "  - Current :",
            (Number(onChainDebtCeiling) / 100).toLocaleString(undefined, {
              minimumFractionDigits: 2,
            })
          );

          if (!fix) {
            continue;
          }

          console.log("[FIX] Updating debt ceiling for", normalizedSymbol);
          const tx = await poolConfigurator.populateTransaction.setDebtCeiling(
            tokenAddress,
            expectedDebtCeiling,
            { gasLimit: 1000000 }
          );

          if (batch) {
            addTransaction(tx);
          } else {
            await waitForTx(await poolConfigurator.signer.sendTransaction(tx));
            const newOnChainDebtCeiling = await dataProvider.getDebtCeiling(
              tokenAddress
            );
            console.log(
              "[FIX] Set",
              normalizedSymbol,
              "debt ceiling to",
              (Number(newOnChainDebtCeiling) / 100).toLocaleString(undefined, {
                minimumFractionDigits: 2,
              })
            );
          }
        } else {
          console.log(
            chalk.green(
              `  - Reserve ${normalizedSymbol} debt ceiling follows the expected configuration`
            )
          );
        }
      }
    }
  );
