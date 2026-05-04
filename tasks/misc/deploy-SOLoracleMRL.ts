import { task } from "hardhat/config";

task(`deploy-SOLoracleMRL`, `Deploys the SOL oracle contract`).setAction(
  async (_, hre) => {
    const mda = "0x6d6e6e7dc8aba5b44845dda12e7d41846d91c653";

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`SOLoracleMRL`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["SOL/USD", 1, mda, 7889000000],
    });

    console.log("SOL oracle deployed at:", artifact.address);
  }
);
