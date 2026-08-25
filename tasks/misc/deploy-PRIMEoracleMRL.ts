import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";

task(`deploy-PRIMEoracleMRL`, `Deploys the PRIME oracle contract`).setAction(
  async (_, hre) => {
    const mda = "0x6d6e6e7dc8aba5b44845dda12e7d41846d91c653";

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`PRIMEoracleMRL`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["PRIME/USD", 1, mda, 101643480],
    });

    console.log("PRIME oracle deployed at:", artifact.address);
  }
);
