import {
  isTestnetMarket,
  loadPoolConfig,
} from "./../helpers/market-config-helpers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { MARKET_NAME } from "../helpers/env";
import { getPoolConfiguratorProxy, waitForTx } from "../helpers";

/**
 * The following script runs after the deployment starts
 */

const func: DeployFunction = async function ({
  getNamedAccounts,
  deployments,
  ...hre
}: HardhatRuntimeEnvironment) {
  console.log("=== Post deployment hook ===");
  const poolConfig = loadPoolConfig(MARKET_NAME);

  if (!isTestnetMarket(poolConfig)) {
    console.log("- Review borrow caps");
    await hre.run("review-borrow-caps", { fix: true });

    console.log("- Review supply caps");
    await hre.run("review-supply-caps", { fix: true });
  }

  console.log("- Enable stable borrow in selected assets");
  await hre.run("review-stable-borrow", { fix: true, vvv: true });

  console.log("- Review rate strategies");
  await hre.run("review-rate-strategies");

  console.log("- Setup Debt Ceiling");
  await hre.run("setup-debt-ceiling");

  console.log("- Setup Borrowable assets in Isolation Mode");
  await hre.run("setup-isolation-mode");

  console.log("- Setup E-Modes");
  await hre.run("setup-e-modes");

  console.log("- Setup Liquidation protocol fee");
  await hre.run("setup-liquidation-protocol-fee");

  if (isTestnetMarket(poolConfig)) {
    // Unpause pool
    const poolConfigurator = await getPoolConfiguratorProxy();
    await waitForTx(await poolConfigurator.setPoolPause(false));
    console.log("- Pool unpaused and accepting deposits.");
  }

  if (process.env.TRANSFER_OWNERSHIP === "true") {
    await hre.run("transfer-protocol-ownership");
    await hre.run("renounce-pool-admin");
    await hre.run("view-protocol-roles");
  }

  await hre.run("print-deployments");
};

func.tags = ["after-deploy"];
func.runAtTheEnd = true;
export default func;
