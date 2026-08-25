import { task } from "hardhat/config";

const WH_ORACLE_UPDATER: string =
  "0x582e2fac5af62dc024396b5e7f549c72273a69c3";

task(
  `deploy-jitoSOLoracleWH`,
  `Deploys the WH jitoSOL ManagedOracle (owned by the WH oracle updater)`
).setAction(async (_, hre) => {
  if (WH_ORACLE_UPDATER === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      "WH_ORACLE_UPDATER is the zero placeholder — set it to the WH oracle updater address before deploying"
    );
  }

  console.log(`\n- jitoSOLoracleWH deployment`);
  const { deployer } = await hre.getNamedAccounts();

  const artifact = await hre.deployments.deploy(`jitoSOLoracleWH`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["jitoSOL/SOL", 1, WH_ORACLE_UPDATER, 129240000],
  });

  console.log("jitoSOLoracleWH (ManagedOracle) deployed at:", artifact.address);
  console.log(`\tFinished jitoSOLoracleWH deployment`);
});
