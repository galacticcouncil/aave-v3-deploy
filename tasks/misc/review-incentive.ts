import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { exit } from "process";
import { MARKET_NAME } from "../../helpers/env";
import { ZERO_ADDRESS, POOL_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import {
  getEmissionManager,
  getUiIncentiveDataProvider,
  getPoolAddressesProvider,
  getAaveProtocolDataProvider,
  getPotRewardsStrategy,
} from "../../helpers/contract-getters";
import chalk from "chalk";
import { addTransaction } from "../../helpers/transaction-batch";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { TransferStrategy, AssetType } from "./../../helpers/types";
import { getBlockTimestamp } from "../../helpers/utilities/tx";
import { BigNumber } from "ethers";

task(`review-incentive`, ``)
  .addFlag("batch")
  .addParam("reserve", "reserve's incentive config")
  .addFlag("update")
  .setAction(
    async (
      {
        batch,
        reserve,
        update,
      }: { batch: boolean; reserve: string; update: boolean },
      hre
    ) => {
      const network = FORK ? FORK : (hre.network.name as eNetwork);
      const admin = POOL_ADMIN[network];
      if (!admin || admin == ZERO_ADDRESS) {
        console.log(chalk.red(`POOL_ADMIN[${network}] is zero address`));
        exit(1);
      }

      const poolConfig = await loadPoolConfig(MARKET_NAME);
      const incentiveConf = poolConfig.IncentivesConfig[network]?.[reserve];
      const em = await getEmissionManager();
      const transferStrat = await getPotRewardsStrategy();

      const inc = await getUiIncentiveDataProvider();
      const poolAddressProvider = await getPoolAddressesProvider();
      const onChainIncentives = await inc.getReservesIncentivesData(
        poolAddressProvider.address
      );

      const dataProvider = await getAaveProtocolDataProvider();
      const reserveTokens = await dataProvider.getAllReservesTokens();

      const chainlinkConf = poolConfig.ChainlinkAggregator[network];
      if (!chainlinkConf) {
        console.log(
          chalk.red(
            `'${network}.${reserve}': chainlink configuration not found`
          )
        );
        exit(1);
      }

      if (!incentiveConf || incentiveConf.length == 0) {
        console.log(
          chalk.red(
            `'${network}.${reserve}': incentive config not found or is not valid`
          )
        );
        exit(1);
      }

      console.log(`'${network}.${reserve}': reviewing incentive`);

      const assetsConf = [];
      for (let i = 0; i < incentiveConf.length; i++) {
        const cfg = incentiveConf[i];

        const reserveAddr = reserveTokens.find(
          (el) => el.symbol == cfg.reserve
        )?.tokenAddress;
        if (!reserveAddr || reserveAddr == ZERO_ADDRESS) {
          console.log(
            chalk.red(`'${network}.${reserve}[${i}]': reserve asset not found`)
          );
          exit(1);
        }

        const oracleAddr = chainlinkConf[cfg.rewardOracle];
        if (!oracleAddr || oracleAddr == ZERO_ADDRESS) {
          console.log(
            chalk.red(
              `'${network}.${reserve}[${i}]': oracle wasn't found in ChainlinkAggregator or is not valid`
            )
          );
          exit(1);
        }

        if (cfg.transferStrategy != TransferStrategy.PotRewardsStrategy) {
          console.log(
            chalk.red(
              `'${network}.${reserve}[${i}]': invalid transfer strategy. Only PotRewardsStrategy is supported`
            )
          );
          exit(1);
        }

        if (!cfg.reward || cfg.reward == ZERO_ADDRESS) {
          console.log(
            chalk.red(`'${network}.${reserve}[${i}]': invalid reward address`)
          );
          exit(1);
        }

        if (cfg.emissionAdmin.toLowerCase() != admin.toLowerCase()) {
          console.log(
            chalk.red(
              `'${network}.${reserve}[${i}]': emission admin is not set to poolAdmin`
            )
          );
          exit(1);
        }

        const onChainInc = onChainIncentives.find(
          (el) => el.underlyingAsset == reserveAddr
        );
        if (!onChainInc) {
          //NOTE: onChainInc should always exists even if incentives were never deployed
          console.log(
            chalk.red(
              `'${network}.${reserve}[${i}]': unexpected error. No incentives data found onchain.`
            )
          );
          exit(1);
        }

        const {
          aTokenAddress,
          stableDebtTokenAddress,
          variableDebtTokenAddress,
        } = await dataProvider.getReserveTokensAddresses(reserveAddr);

        let activeInc;
        let asset;
        switch (cfg.incentivizedToken) {
          case AssetType.AToken:
            activeInc = onChainInc.aIncentiveData.rewardsTokenInformation.find(
              (el) => el.rewardTokenAddress == cfg.reward
            );
            asset = aTokenAddress;
            break;
          case AssetType.VariableDebtToken:
            activeInc = onChainInc.vIncentiveData.rewardsTokenInformation.find(
              (el) => el.rewardTokenAddress == cfg.reward
            );
            asset = variableDebtTokenAddress;
            break;
          case AssetType.StableDebtToken:
            activeInc = onChainInc.sIncentiveData.rewardsTokenInformation.find(
              (el) => el.rewardTokenAddress == cfg.reward
            );
            asset = stableDebtTokenAddress;
            break;
          default:
            console.log(
              chalk.red(
                `'${network}.${reserve}[${i}]': unknown incentivizedToken option: ${cfg.incentivizedToken}`
              )
            );
            exit(1);
        }

        const now = await getBlockTimestamp();

        if (
          activeInc?.emissionEndTimestamp.gt(BigNumber.from(now)) &&
          !update
        ) {
          console.log(
            chalk.yellow(
              `'${network}.${reserve}[${i}]': liquidity mining is active. To update it use --update`
            )
          );
          continue;
        }

        //start or update incentives
        assetsConf.push({
          emissionPerSecond: cfg.emissionPerSecond,
          distributionEnd: now + cfg.duration,
          asset: asset,
          reward: cfg.reward,
          transferStrategy: transferStrat.address,
          rewardOracle: oracleAddr,
          totalSupply: "0",
        });
      }

      if (assetsConf.length != 0) {
        const tx = await em.populateTransaction.configureAssets(assetsConf, {
          gasLimit: 1000000,
        });
        addTransaction(tx);
      }

      if (batch) {
        return;
      } else {
        console.log(
          chalk.red(
            `'${network}.${reserve}': direct sending transaction is not supported`
          )
        );
        exit(1);
      }
    }
  );
