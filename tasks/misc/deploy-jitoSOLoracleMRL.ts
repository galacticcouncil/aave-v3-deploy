import { task } from "hardhat/config";

task(`deploy-jitoSOLoracleMRL`, `Deploys the jitoSOL oracle contract`).setAction(
  async (_, hre) => {
    const mda = "0x6d6e6e7dc8aba5b44845dda12e7d41846d91c653";

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`jitoSOLoracleMRL`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["jitoSOL/SOL", 1, mda, 127113700],
    });

    console.log("jitoSOL oracle deployed at:", artifact.address);
  }
);
