import { task } from "hardhat/config";
import { exit } from "process";
import { loadPoolConfig } from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { ZERO_ADDRESS } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { addTransaction, getBatch } from "../../helpers/transaction-batch";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { getEmissionManager, getAaveProtocolDataProvider } from "../../helpers/contract-getters";
import { TransferStrategy, AssetType } from "./../../helpers/types";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import { getBlockTimestamp } from "../../helpers/utilities/tx";
import chalk from "chalk";

task(`setup-incentives`, `Updates incentives program or starts new one if incentives doesn't exists.`)
  .addParam("assets")
  .setAction(async (
      {
        assets,
      }: { assets: string },
      hre
    ) => {
  const network = FORK ? FORK : (hre.network.name as eNetwork);

  assets = assets.replaceAll(/\s/g, "").split(",")
  if (assets.length == 0) {
    console.log(chalk.red(`invalid '--assets' value, usage: --assets DOT,USDT`));
    exit(1);
  }

  const poolConfig = await loadPoolConfig(MARKET_NAME);
  const chainlinkConf = poolConfig.ChainlinkAggregator[network];
  const incentivesConf = poolConfig.IncentivesConfig[network];
  const em = await getEmissionManager();

  if (!chainlinkConf) {
    console.log(chalk.red(`chainlink configuration for ${network} network not found`));
    exit(1);
  }

  const incentivizedTkns = Object.keys(incentivesConf);
  const assetsConf = [];
  const transferStrat = await getPotRewardsStrategy();
  var emissionAdmin;

  const dataProvider = await getAaveProtocolDataProvider();
  const reserveTokens = await dataProvider.getAllReservesTokens();

  for (let i = 0; i < assets.length; i++ ) {
    const incTkn = assets[i];
    const cfg = incentivesConf[incTkn];

    if (!cfg) {
      console.log(chalk.red(`Incentives config not found for asset: '${incTkn}'`));
      exit(1);
    }

    const reserve = reserveTokens.find((el) => el.symbol == cfg.asset);
    if (!reserve || reserve == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: reserve asset not found for asset: ${cfg.asset}`));
      exit(1);
    }

    const {
      aTokenAddress,
      stableDebtTokenAddress,
      variableDebtTokenAddress,
    } = await dataProvider.getReserveTokensAddresses(reserve.tokenAddress);

    let asset;
    switch (cfg.assetType) {
      case AssetType.AToken:
        asset = aTokenAddress;
        break;
      case AssetType.VariableDebtToken:
        asset = variableDebtTokenAddress;
        break;
      case AssetType.StableDebtToken:
        asset = stableDebtTokenAddress;
        break;
      default:
      console.log(chalk.red(`${incTkn}: unknown assetType option: ${cfg.assetType}`));
      exit(1);
    }

    if (!asset || asset == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: asset's address not found or is zero address`));
      exit(1);
    }

    const oracleAddr = chainlinkConf[cfg.rewardOracle];
    if (!oracleAddr || oracleAddr == ZERO_ADDRESS ) {
      console.log(chalk.red(`${incTkn}: reward's address is zero addresss or wasn't found in ChainlinkAggregator`));
      exit(1);
    }

    if (cfg.transferStrategy != TransferStrategy.PotRewardsStrategy) {
      console.log(chalk.red(`${incTkn}: invalid transfer strategy. Only PotRewardsStrategy is supported`));
      exit(1);
    }

    if (!cfg.reward || cfg.reward == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid reward value: ${cfg.reward}`));
      exit(1);
    }
    const emAdmin = await em.getEmissionAdmin(cfg.reward);
    if (!emAdmin || emAdmin.toLowerCase() != cfg.emissionAdmin.toLowerCase() || emAdmin == ZERO_ADDRESS) {
      console.log(chalk.red(`${incTkn}: invalid emission admin for reward asset: ${cfg.reward}. onchain admin: ${emAdmin}, configured admin: ${cfg.emissionAdmin}`));
      exit(1);
    }

    if (!emissionAdmin) {
      emissionAdmin = emAdmin;
    }

    if (emissionAdmin.toLowerCase() != emAdmin.toLowerCase()) {
      console.log(chalk.red(`${incTkn}: all incentives doesn't have same emission admin. Transactions can't be batched`));
      exit(1);
    }

    const time = await getBlockTimestamp();
    assetsConf.push({
      emissionPerSecond: cfg.emissionPerSecond,
      distributionEnd: time + cfg.duration,
      asset: asset,
      reward: cfg.reward,
      transferStrategy: transferStrat.address,
      rewardOracle: oracleAddr,
      totalSupply: "0",
    })
  }

  if (assetsConf.length == 0) {
    console.log("no incentives to setup/update")
    return;
  }

  let tx = await em.populateTransaction.configureAssets(assetsConf, { gasLimit: 1000000 });
  const { preimages, whitelist, proposal, whitelistedCall } =
     await generateProposal([tx], emissionAdmin, [], true);

   const decoder = new ProposalDecoder(hre);
   await decoder.init();
   console.log("submit preimages:");
   console.log(preimages.toHex());
   decoder.printTree(decoder.transformCall(preimages.toHuman()));
   console.log("whitelisted call hash:", whitelistedCall.hash.toHex());
   console.log(whitelistedCall.toHex());
   decoder.printTree(decoder.transformCall(whitelistedCall.toHuman()));
   console.log("whitelist call hash:", whitelistedCall.hash.toHex());
   console.log(whitelist.toHex());
   decoder.printTree(decoder.transformCall(whitelist.toHuman()));
   console.log("whitelisted proposal:");
   console.log(proposal.toHex());
   decoder.printTree(decoder.transformCall(proposal.toHuman()));
   console.log("whitelisted proposal hash:");
   console.log(proposal.hash.toHex());
});
