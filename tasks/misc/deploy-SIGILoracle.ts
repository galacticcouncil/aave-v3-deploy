import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";

task(`deploy-SIGILoracle`, `Deploys the SIGIL oracle contract`).setAction(
  async (_, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const network = hre.network.name;
    const admin = POOL_ADMIN[network];

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`SIGILoracle`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["SIGIL/USD", 1, admin, 100000000],
    });

    console.log("SIGIL oracle deployed at:", artifact.address);
  }
);
