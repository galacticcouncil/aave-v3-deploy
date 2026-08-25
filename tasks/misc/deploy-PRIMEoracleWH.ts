import { task } from "hardhat/config";

const WH_ORACLE_UPDATER: string =
  "0x582e2fac5af62dc024396b5e7f549c72273a69c3";

task(
  `deploy-PRIMEoracleWH`,
  `Deploys the WH PRIME ManagedOracle (owned by the WH oracle updater)`
).setAction(async (_, hre) => {
  if (WH_ORACLE_UPDATER === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      "WH_ORACLE_UPDATER is the zero placeholder — set it to the WH oracle updater address before deploying"
    );
  }

  console.log(`\n- PRIMEoracleWH deployment`);
  const { deployer } = await hre.getNamedAccounts();

  const artifact = await hre.deployments.deploy(`PRIMEoracleWH`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["PRIME/USD", 1, WH_ORACLE_UPDATER, 105125295],
  });

  console.log("PRIMEoracleWH (ManagedOracle) deployed at:", artifact.address);
  console.log(`\tFinished PRIMEoracleWH deployment`);
});
