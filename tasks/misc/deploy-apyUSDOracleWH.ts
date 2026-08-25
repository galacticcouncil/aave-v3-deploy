import { task } from "hardhat/config";

const WH_ORACLE_UPDATER: string =
  "0x6913770466fed4dbc24337cd7f1ae92af4321083";

task(
  `deploy-apyUSDOracleWH`,
  `Deploys the WH apyUSD ManagedOracle (owned by the WH oracle updater)`
).setAction(async (_, hre) => {
  if (WH_ORACLE_UPDATER === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      "WH_ORACLE_UPDATER is the zero placeholder — set it to the WH oracle updater address before deploying"
    );
  }

  console.log(`\n- apyUSDOracleWH deployment`);
  const { deployer } = await hre.getNamedAccounts();

  const artifact = await hre.deployments.deploy(`apyUSDOracleWH`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["apyUSD/apxUSD", 1, WH_ORACLE_UPDATER, 140400988],
  });

  console.log("apyUSDOracleWH (ManagedOracle) deployed at:", artifact.address);
  console.log(`\tFinished apyUSDOracleWH deployment`);
});
