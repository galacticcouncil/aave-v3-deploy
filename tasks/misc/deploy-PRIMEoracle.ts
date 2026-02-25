import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";

task(`deploy-PRIMEoracle`, `Deploys the PRIME oracle contract`).setAction(
  async (_, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const network = hre.network.name;
    const admin = POOL_ADMIN[network];

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`PRIMEoracle`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["PRIME/USD", 1, admin, 101953577],
    });

    console.log("PRIME oracle deployed at:", artifact.address);
  }
);
