import {
  STAKE_AAVE_PROXY,
  TESTNET_REWARD_TOKEN_PREFIX,
} from "../../../helpers/deploy-ids";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { COMMON_DEPLOY_PARAMS } from "../../../helpers/env";
import {
  checkRequiredEnvironment,
  ConfigNames,
  isIncentivesEnabled,
  isProductionMarket,
  loadPoolConfig,
} from "../../../helpers/market-config-helpers";
import { eNetwork } from "../../../helpers/types";
import {
  // FAUCET_ID,
  TESTNET_TOKEN_PREFIX,
  FAUCET_OWNABLE_ID,
} from "../../../helpers/deploy-ids";
import Bluebird from "bluebird";
import {
  deployInitializableAdminUpgradeabilityProxy,
  setupStkAave,
} from "../../../helpers/contract-deployments";
import { MARKET_NAME, PERMISSIONED_FAUCET } from "../../../helpers/env";

const func: DeployFunction = async function ({
  getNamedAccounts,
  deployments,
  ...hre
}: HardhatRuntimeEnvironment) {
  const { deploy } = deployments;
  const { deployer, incentivesEmissionManager, incentivesRewardsVault } =
    await getNamedAccounts();
  const poolConfig = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const network = (
    process.env.FORK ? process.env.FORK : hre.network.name
  ) as eNetwork;

  console.log("Live network:", !!hre.config.networks[network].live);

  if (isProductionMarket(poolConfig)) {
    console.log(
      "[Deployment] Skipping testnet token setup at production market"
    );
    // Early exit if is not a testnet market
    return;
  }
  // Deployment of FaucetOwnable helper contract
  // TestnetERC20 is owned by Faucet. Faucet is owned by defender relayer.
  console.log("- Deployment of FaucetOwnable contract");
  const faucetOwnable = await deploy(FAUCET_OWNABLE_ID, {
    from: deployer,
    contract: "Faucet",
    args: [deployer, PERMISSIONED_FAUCET, 10000], // 10000 whole tokens
    ...COMMON_DEPLOY_PARAMS,
  });

  console.log(
    `- Setting up testnet tokens for "${MARKET_NAME}" market at "${network}" network`
  );

  const reservesConfig = poolConfig.ReservesConfig;
  const reserveSymbols = Object.keys(reservesConfig);

  if (reserveSymbols.length === 0) {
    console.warn(
      "Market Config does not contain ReservesConfig. Skipping testnet token setup."
    );
    return;
  }

  // 0. Deployment of ERC20 mintable tokens for testing purposes
  await Bluebird.each(reserveSymbols, async (symbol) => {
    if (!reservesConfig[symbol]) {
      throw `[Deployment] Missing token "${symbol}" at ReservesConfig`;
    }

    if (symbol == poolConfig.WrappedNativeTokenSymbol) {
      console.log("Deploy of WETH9 mock");
      await deploy(
        `${poolConfig.WrappedNativeTokenSymbol}${TESTNET_TOKEN_PREFIX}`,
        {
          from: deployer,
          contract: "WETH9Mock",
          args: [
            poolConfig.WrappedNativeTokenSymbol,
            poolConfig.WrappedNativeTokenSymbol,
            faucetOwnable.address,
          ],
          ...COMMON_DEPLOY_PARAMS,
        }
      );
    } else {
      console.log("Deploy of TestnetERC20 contract", symbol);
      await deploy(`${symbol}${TESTNET_TOKEN_PREFIX}`, {
        from: deployer,
        contract: "TestnetERC20",
        args: [
          symbol,
          symbol,
          reservesConfig[symbol].reserveDecimals,
          faucetOwnable.address,
        ],
        ...COMMON_DEPLOY_PARAMS,
      });
    }
  });

  console.log(
    "[Deployment][WARNING] Remember to setup the above testnet addresses at the ReservesConfig field inside the market configuration file and reuse testnet tokens"
  );
  console.log(
    "[Deployment][WARNING] Remember to setup the Native Token Wrapper (ex WETH or WMATIC) at `helpers/constants.ts`"
  );
};

func.tags = ["market", "init-testnet", "token-setup"];

func.dependencies = ["before-deploy", "periphery-pre"];

func.skip = async () => checkRequiredEnvironment();

export default func;
