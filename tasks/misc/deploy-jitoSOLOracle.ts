import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";

task(`deploy-jitoSOLOracle`, `Deploys the jitoSOLOracle contract`).setAction(
  async (_, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const network = hre.network.name;
    const admin = POOL_ADMIN[network];

    console.log(`\n- jitoSOLOracle deployment`);
    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`jitoSOLOracle`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["jitoSOL/SOL", 1, admin, 125672373], // TODO: Set correct initial jitoSOL/SOL ratio, from their program https://www.jito.network/staking/?mode=unstake
    });

    console.log("ManagedOracle deployed at:", artifact.address);
    console.log(`\tFinished jitoSOLOracle deployment`);
  }
);
