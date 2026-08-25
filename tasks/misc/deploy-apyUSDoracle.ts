import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";

task(`deploy-apyUSDoracle`, `Deploys the apyUSD oracle contract`).setAction(
  async (_, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const network = hre.network.name;
    const admin = POOL_ADMIN[network];

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`apyUSDoracle`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["apyUSD/USD", 1, admin, 136723180],
    });

    console.log("apyUSD oracle deployed at:", artifact.address);
  }
);
