import { task } from "hardhat/config";

task(
  `deploy-HDCLOracleAdapter`,
  `Deploys HDCLOracleAdapter for the given HDCL vault proxy`
)
  .addParam("vault", "HDCL vault proxy address")
  .setAction(async ({ vault }: { vault: string }, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }

    console.log(`\n- HDCLOracleAdapter deployment`);
    console.log(`  vault: ${vault}`);

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`HDCLOracleAdapter`, {
      from: deployer,
      contract: "HDCLOracleAdapter",
      args: [vault],
    });

    console.log("HDCLOracleAdapter deployed at:", artifact.address);
  });
