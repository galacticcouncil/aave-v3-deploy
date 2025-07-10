import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";

task(`deploy-wstETHOracle`, `Deploys the wstETHOracle contract`).setAction(
  async (_, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const network = hre.network.name;
    const admin = POOL_ADMIN[network];

    console.log(`\n- wstETHOracle deployment`);
    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`wstETHOracle`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["wstETH/ETH", 1, admin, 120780546],
    });

    console.log("USDOracleAdapter deployed at:", artifact.address);
    console.log(`\tFinished USDOracleAdapter deployment`);
  }
);
