import { task } from "hardhat/config";

const WH_ORACLE_UPDATER: string =
  "0x6913770466fed4dbc24337cd7f1ae92af4321083";

task(
  `deploy-wstETHOracleWH`,
  `Deploys the WH wstETH ManagedOracle (owned by the WH oracle updater)`
).setAction(async (_, hre) => {
  if (WH_ORACLE_UPDATER === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      "WH_ORACLE_UPDATER is the zero placeholder — set it to the WH oracle updater address before deploying"
    );
  }

  console.log(`\n- wstETHOracleWH deployment`);
  const { deployer } = await hre.getNamedAccounts();

  const artifact = await hre.deployments.deploy(`wstETHOracleWH`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["wstETH/ETH", 1, WH_ORACLE_UPDATER, 124054875],
  });

  console.log("wstETHOracleWH (ManagedOracle) deployed at:", artifact.address);
  console.log(`\tFinished wstETHOracleWH deployment`);
});
