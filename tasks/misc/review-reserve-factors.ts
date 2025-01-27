import { eNetwork } from "../../helpers/types";
import {
  POOL_CONFIGURATOR_PROXY_ID,
  POOL_DATA_PROVIDER,
} from "../../helpers/deploy-ids";
import { getAddressFromJson } from "../../helpers/utilities/tx";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { getPoolConfiguratorProxy } from "../../helpers/contract-getters";
import { task } from "hardhat/config";
import { waitForTx } from "../../helpers/utilities/tx";
import { getAaveProtocolDataProvider } from "../../helpers/contract-getters";
import { MARKET_NAME } from "../../helpers/env";
import { FORK } from "../../helpers/hardhat-config-helpers";
import chalk from "chalk";
import { exit } from "process";
import { getAddress } from "ethers/lib/utils";
import { addTransaction } from "../../helpers/transaction-batch";

task(`review-reserve-factors`, ``)
  .addFlag("fix")
  .addOptionalParam("checkOnly")
  .addFlag("batch")
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
      const reserves = await dataProvider.getAllReservesTokens();

      const reservesToCheck = checkOnlyReserves.length
        ? reserves.filter(([reserveSymbol]) =>
            checkOnlyReserves.includes(reserveSymbol)
          )
        : reserves;

      const reserveAssets = poolConfig.ReserveAssets?.[network];
      if (!reserveAssets) {
        console.log("Exiting due missing ReserveAssets");
        exit(2);
      }

      for (let index = 0; index < reservesToCheck.length; index++) {
        const { symbol, tokenAddress } = reservesToCheck[index];

        let normalizedSymbol = "";
        Object.values(reserveAssets).forEach((value, index) => {
          if (getAddress(value) === getAddress(tokenAddress)) {
            normalizedSymbol = Object.keys(reserveAssets)[index];
          }
        });
        if (!normalizedSymbol) {
          console.error(
            `- Missing address ${tokenAddress} at ReserveAssets configuration.`
          );
          exit(3);
        }

        console.log("- Checking reserve", symbol);
        const expectedReserveFactor =
          poolConfig.ReservesConfig[normalizedSymbol.toUpperCase()]
            .reserveFactor;
        const onChainReserveFactor = (
          await dataProvider.getReserveConfigurationData(tokenAddress)
        ).reserveFactor.toString();

        const delta = expectedReserveFactor !== onChainReserveFactor;
        if (delta) {
          console.log(
            "- Found differences of the reserve factor for",
            normalizedSymbol
          );
          console.log("  - Expected:", expectedReserveFactor);
          console.log("  - Current :", onChainReserveFactor);

          if (!fix) {
            continue;
          }
          console.log(
            "[FIX] Updating the reserve factor for",
            normalizedSymbol
          );
          const tx =
            await poolConfigurator.populateTransaction.setReserveFactor(
              tokenAddress,
              expectedReserveFactor,
              { gasLimit: 100000 }
            );
          if (batch) {
            addTransaction(tx);
          } else {
            await waitForTx(await poolConfigurator.signer.sendTransaction(tx));
            const newOnChainReserveFactor = (
              await dataProvider.getReserveConfigurationData(tokenAddress)
            ).reserveFactor.toString();
            console.log(
              "[FIX] Set",
              normalizedSymbol,
              "reserve factor to",
              newOnChainReserveFactor
            );
          }
        } else {
          console.log(
            chalk.green(
              `  - Reserve ${normalizedSymbol} reserve factor follows the expected configuration`
            )
          );
          continue;
        }
      }
    }
  );
