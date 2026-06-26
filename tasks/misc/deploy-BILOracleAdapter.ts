import { task } from "hardhat/config";

task(
  `deploy-BILOracleAdapter`,
  `Deploys BILOracleAdapter for the given BIL vault proxy`
)
  .addParam("vault", "BIL vault proxy address")
  .setAction(async ({ vault }: { vault: string }, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }

    console.log(`\n- BILOracleAdapter deployment`);
    console.log(`  vault: ${vault}`);

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`BILOracleAdapter`, {
      from: deployer,
      contract: "BILOracleAdapter",
      args: [vault],
    });

    console.log("BILOracleAdapter deployed at:", artifact.address);
  });
