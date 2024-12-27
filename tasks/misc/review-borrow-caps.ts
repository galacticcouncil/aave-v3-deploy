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
import { getAddress } from "ethers/lib/utils";

// If the fix flag is present it will change the borrow cap to the expected local market configuration
task(`review-borrow-caps`, ``)
  // --fix
  .addFlag("fix")
  // Optional parameter to check only the desired tokens by symbol and separated by comma
  // --checkOnly DAI,USDC,ETH
  .addOptionalParam("checkOnly")
  .setAction(
    async ({ fix, checkOnly }: { fix: boolean; checkOnly: string }, hre) => {
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

        console.log(
          "- Checking reserve",
          symbol,
          `, normalized symbol`,
          normalizedSymbol
        );
        const expectedBorrowCap =
          poolConfig.ReservesConfig[normalizedSymbol.toUpperCase()].borrowCap;
        const onChainBorrowCap = (
          await dataProvider.getReserveCaps(tokenAddress)
        ).borrowCap.toString();

        const delta = expectedBorrowCap !== onChainBorrowCap;
        if (delta) {
          console.log(
            "- Found differences of the borrow cap for ",
            normalizedSymbol
          );
          console.log(
            "  - Expected:",
            Number(expectedBorrowCap).toLocaleString(undefined, {
              currency: "usd",
            })
          );
          console.log(
            "  - Current :",
            Number(onChainBorrowCap).toLocaleString(undefined, {
              currency: "usd",
            })
          );

          if (!fix) {
            const tx = await poolConfigurator.populateTransaction.setBorrowCap(
              tokenAddress,
              expectedBorrowCap,
              { gasLimit: 1000000 }
            );
            console.log("  - Transaction to fix:");
            console.log(tx);
            continue;
          }
          console.log("[FIX] Updating the borrow cap for", normalizedSymbol);
          await waitForTx(
            await poolConfigurator.setBorrowCap(
              tokenAddress,
              expectedBorrowCap,
              { gasLimit: 1000000 }
            )
          );
          const newOnChainBorrowCap = (
            await dataProvider.getReserveCaps(tokenAddress)
          ).borrowCap.toString();
          console.log(
            "[FIX] Set ",
            normalizedSymbol,
            "Borrow cap to",
            Number(newOnChainBorrowCap).toLocaleString(undefined, {
              currency: "usd",
            })
          );
        } else {
          console.log(
            chalk.green(
              `  - Reserve ${normalizedSymbol} borrow cap follows the expected configuration`
            )
          );
        }
      }
    }
  );
