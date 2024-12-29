import { getFirstSigner } from "../../helpers/utilities/signer";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import {
  getAaveProtocolDataProvider,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
} from "../../helpers/contract-getters";
import { IInterestRateStrategyParams } from "../../helpers/types";
import { task } from "hardhat/config";
import { waitForTx } from "../../helpers/utilities/tx";
import { MARKET_NAME } from "../../helpers/env";
import { diff, formatters } from "jsondiffpatch";
import chalk from "chalk";
import { DefaultReserveInterestRateStrategy } from "../../typechain";
import { addTransaction } from "../../helpers/transaction-batch";

// This task will review the InterestRate strategy of each reserve from a Market passed by environment variable MARKET_NAME.
// If the fix flag is present it will change the current strategy of the reserve to the desired strategy from market configuration.
task(`review-rate-strategies`, ``)
  // Flag to fix the reserve deploying a new InterestRateStrategy contract with the strategy from market configuration:
  // --fix
  .addFlag("fix")
  .addFlag("deploy")
  // Optional parameter to check only the desired tokens by symbol and separated by comma
  // --only DAI,USDC,ETH
  .addOptionalParam("only")
  .addFlag("batch")
  .setAction(
    async (
      {
        fix,
        deploy,
        only,
        batch = false,
      }: { fix: boolean; only: string; deploy: boolean; batch: boolean },
      hre
    ) => {
      const { deployer, poolAdmin } = await hre.getNamedAccounts();
      const checkOnlyReserves: string[] = only ? only.split(",") : [];
      const dataProvider = await getAaveProtocolDataProvider();
      const poolConfigurator = (await getPoolConfiguratorProxy()).connect(
        await hre.ethers.getSigner(poolAdmin)
      );
      const poolAddressesProvider = await getPoolAddressesProvider();
      const poolConfig = await loadPoolConfig(MARKET_NAME);
      const reserves = await dataProvider.getAllReservesTokens();

      const reservesToCheck = checkOnlyReserves.length
        ? reserves.filter(([reserveSymbol]) =>
            checkOnlyReserves.includes(reserveSymbol)
          )
        : reserves;

      for (let index = 0; index < reservesToCheck.length; index++) {
        const { symbol, tokenAddress } = reservesToCheck[index];

        const normalizedSymbol = symbol.toUpperCase();
        console.log(symbol, normalizedSymbol, tokenAddress);
        if (!normalizedSymbol) {
          console.warn(
            `- Missing address ${tokenAddress} at ReserveAssets configuration for ${symbol}`
          );
          continue;
        }

        console.log(
          "- Checking reserve",
          symbol,
          `, normalized symbol`,
          normalizedSymbol
        );
        const expectedStrategy: IInterestRateStrategyParams =
          poolConfig.ReservesConfig[normalizedSymbol.toUpperCase()].strategy;
        const onChainStrategy =
          await dataProvider.getInterestRateStrategyAddress(tokenAddress);
        const delta = await compareStrategy(
          hre,
          onChainStrategy,
          expectedStrategy
        );
        if (delta) {
          console.log(
            `- Found ${chalk.red(
              "differences"
            )} at reserve ${normalizedSymbol} versus expected "${
              expectedStrategy.name
            }" strategy from configuration`
          );
          console.log(
            chalk.red(
              "Current strategy",
              "=>",
              chalk.green("Desired strategy from config")
            )
          );
          console.log(formatters.console.format(delta, expectedStrategy));

          if (deploy) {
            let newStrategyAddress;
            const strategyName = `ReserveStrategy-${expectedStrategy.name}`;
            const strategy = await hre.deployments.getOrNull(strategyName);
            if (strategy && strategy.address !== onChainStrategy) {
              console.log(
                "  - Desired strategy already deployed at",
                strategy.address
              );
              const delta = await compareStrategy(
                hre,
                strategy.address,
                expectedStrategy
              );
              if (delta) {
                console.warn(
                  "  - Deployed strategy does not match the expected configuration"
                );
              } else {
                newStrategyAddress = strategy.address;
              }
            }

            if (!newStrategyAddress) {
              console.log(`Deployer: ${deployer}`);
              console.log(`  - Deploying a new instance of ${strategyName}`);
              const deployArgs = [
                poolAddressesProvider.address,
                expectedStrategy.optimalUsageRatio,
                expectedStrategy.baseVariableBorrowRate,
                expectedStrategy.variableRateSlope1,
                expectedStrategy.variableRateSlope2,
                expectedStrategy.stableRateSlope1,
                expectedStrategy.stableRateSlope2,
                expectedStrategy.baseStableRateOffset,
                expectedStrategy.stableRateExcessOffset,
                expectedStrategy.optimalStableToTotalDebtRatio,
              ];
              const fixedInterestStrategy = await hre.deployments.deploy(
                strategyName,
                {
                  from: deployer,
                  args: deployArgs,
                  contract: "DefaultReserveInterestRateStrategy",
                  log: true,
                }
              );
              console.log(
                "  - Deployed new Reserve Interest Strategy of",
                normalizedSymbol,
                "at",
                fixedInterestStrategy.address
              );
              newStrategyAddress = fixedInterestStrategy.address;
            }

            if (fix) {
              console.log(
                "  - Setting new Reserve Interest Strategy address for reserve",
                normalizedSymbol,
                " -> ",
                `${strategyName}(${newStrategyAddress})`
              );
              if (batch) {
                const tx =
                  await poolConfigurator.populateTransaction.setReserveInterestRateStrategyAddress(
                    tokenAddress,
                    newStrategyAddress,
                    { gasLimit: 100000 }
                  );
                addTransaction(tx);
              } else {
                await waitForTx(
                  await poolConfigurator.setReserveInterestRateStrategyAddress(
                    tokenAddress,
                    newStrategyAddress,
                    { gasLimit: 100000 }
                  )
                );
                console.log(
                  "  - Updated Reserve Interest Strategy of",
                  normalizedSymbol,
                  "at",
                  newStrategyAddress
                );
              }
            }
          }
        } else {
          console.log(
            chalk.green(
              `  - Reserve ${normalizedSymbol} Interest Rate Strategy matches the expected configuration`
            )
          );
          continue;
        }
      }
    }
  );

async function compareStrategy(hre, strategyAddress, expectedStrategy) {
  const onChainStrategy = (await hre.ethers.getContractAt(
    "DefaultReserveInterestRateStrategy",
    strategyAddress,
    await getFirstSigner()
  )) as DefaultReserveInterestRateStrategy;
  const currentStrategy: IInterestRateStrategyParams = {
    name: expectedStrategy.name,
    optimalUsageRatio: (await onChainStrategy.OPTIMAL_USAGE_RATIO()).toString(),
    baseVariableBorrowRate: await (
      await onChainStrategy.getBaseVariableBorrowRate()
    ).toString(),
    variableRateSlope1: await (
      await onChainStrategy.getVariableRateSlope1()
    ).toString(),
    variableRateSlope2: await (
      await onChainStrategy.getVariableRateSlope2()
    ).toString(),
    stableRateSlope1: await (
      await onChainStrategy.getStableRateSlope1()
    ).toString(),
    stableRateSlope2: await (
      await onChainStrategy.getStableRateSlope2()
    ).toString(),
    baseStableRateOffset: await (
      await onChainStrategy.getBaseStableBorrowRate()
    )
      .sub(await onChainStrategy.getVariableRateSlope1())
      .toString(),
    stableRateExcessOffset: await (
      await onChainStrategy.getStableRateExcessOffset()
    ).toString(),
    optimalStableToTotalDebtRatio: await (
      await onChainStrategy.OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO()
    ).toString(),
  };

  return diff(currentStrategy, expectedStrategy);
}
