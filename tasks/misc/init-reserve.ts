import { HardhatRuntimeEnvironment } from "hardhat/types";
import {
  ConfigNames,
  getChainlinkOracles,
  getReserveAddresses,
  getTreasuryAddress,
  loadPoolConfig,
  savePoolTokens,
} from "../../helpers/market-config-helpers";
import {
  eNetwork,
  IAaveConfiguration,
  IInterestRateStrategyParams,
} from "../../helpers/types";
import {
  configureReservesByHelper,
  getPairsTokenAggregator,
  initReservesByHelper,
} from "../../helpers/init-helpers";
import {
  ORACLE_ID,
  POOL_ADDRESSES_PROVIDER_ID,
  POOL_DATA_PROVIDER,
} from "../../helpers/deploy-ids";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction } from "../../helpers/transaction-batch";

task(`init-reserve`, ``)
  .addParam("symbol", "symbol of the reserve")
  .addFlag("batch", "Batch transactions")
  .setAction(initReserve);

async function initReserve(
  { symbol, batch = false }: { symbol: string; batch: boolean },
  hre: HardhatRuntimeEnvironment
) {
  const { deployments, getNamedAccounts } = hre;
  const network = (
    process.env.FORK ? process.env.FORK : hre.network.name
  ) as eNetwork;
  const { deployer } = await getNamedAccounts();
  console.log(`deployer: ${deployer}`);

  const poolConfig = (await loadPoolConfig(
    MARKET_NAME as ConfigNames
  )) as IAaveConfiguration;

  const addressProviderArtifact = await deployments.get(
    POOL_ADDRESSES_PROVIDER_ID
  );

  const {
    ATokenNamePrefix,
    StableDebtTokenNamePrefix,
    VariableDebtTokenNamePrefix,
    SymbolPrefix,
    ReservesConfig,
  } = poolConfig;

  const reservesAddresses = await getReserveAddresses(poolConfig, network);

  const reserveAddress = reservesAddresses[symbol.toUpperCase()];
  if (!reserveAddress) {
    console.error(`Reserve ${symbol} not found`);
    return;
  }

  const reserve = { [symbol.toUpperCase()]: reserveAddress };
  {
    const chainlinkAggregators = await getChainlinkOracles(poolConfig, network);

    const [assets, sources] = getPairsTokenAggregator(
      reserve,
      chainlinkAggregators
    );

    const { abi, address } = await deployments.get(ORACLE_ID);
    const oracle = (await hre.ethers.getContractAt(abi, address)).connect(
      await hre.ethers.getSigner(deployer)
    );
    console.log("setting oracle source", assets, sources);
    if (batch) {
      const tx = await oracle.populateTransaction.setAssetSources(
        assets,
        sources
      );
      addTransaction(tx);
    } else {
      await oracle.setAssetSources(assets, sources);
    }
  }

  const strategy: IInterestRateStrategyParams =
    ReservesConfig[symbol.toUpperCase()].strategy;

  const strategyName = `ReserveStrategy-${strategy.name}`;
  const deployedStrategy = await deployments.getOrNull(strategyName);
  if (deployedStrategy) {
    console.log(`Strategy ${strategyName} already deployed`);
  } else {
    console.log(`Deploying ${strategyName}`);
    const args = [
      addressProviderArtifact.address,
      strategy.optimalUsageRatio,
      strategy.baseVariableBorrowRate,
      strategy.variableRateSlope1,
      strategy.variableRateSlope2,
      strategy.stableRateSlope1,
      strategy.stableRateSlope2,
      strategy.baseStableRateOffset,
      strategy.stableRateExcessOffset,
      strategy.optimalStableToTotalDebtRatio,
    ];
    await deployments.deploy(strategyName, {
      from: deployer,
      args: args,
      contract: "DefaultReserveInterestRateStrategy",
      log: true,
    });
  }

  const treasuryAddress = await getTreasuryAddress(poolConfig, network);
  const incentivesController = await deployments.get("IncentivesProxy");

  console.log(`Initializing`, reserve);

  await initReservesByHelper(
    ReservesConfig,
    reserve,
    ATokenNamePrefix,
    StableDebtTokenNamePrefix,
    VariableDebtTokenNamePrefix,
    SymbolPrefix,
    deployer,
    treasuryAddress,
    incentivesController.address,
    batch
  );
  deployments.log(`Initialized reserve`);

  console.log(`Configuring`, reserve);
  await configureReservesByHelper(ReservesConfig, reserve, batch);

  const dataProvider = await deployments.get(POOL_DATA_PROVIDER);
  await savePoolTokens(reserve, dataProvider.address);

  deployments.log(`Configured reserve`);
  return true;
}
