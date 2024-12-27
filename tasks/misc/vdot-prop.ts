import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction, getBatch } from "../../helpers/transacation-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
} from "../../helpers";

task(`vdot-prop`, ``).setAction(async function (_, hre) {
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolConfigurator = (await getPoolConfiguratorProxy()).connect(signer);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  console.log("init VDOT reserve");
  await hre.run("init-reserve", {
    symbol: "VDOT",
    batch: true,
  });

  console.log("update rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  console.log("add VDOT to DOT emode");
  {
    const id = config.EModes["DotEMode"].id;
    const assetAddress = await getReserveAddress(config, "VDOT");
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(
      assetAddress,
      id
    );
    addTransaction(tx);
  }

  console.log("update WBTC reserve");
  {
    const assetAddress = await getReserveAddress(config, "WBTC");
    const reserveConfig = config.ReservesConfig["WBTC"];
    const tx =
      await poolConfigurator.populateTransaction.configureReserveAsCollateral(
        assetAddress,
        reserveConfig.baseLTVAsCollateral,
        reserveConfig.liquidationThreshold,
        reserveConfig.liquidationBonus
      );
    addTransaction(tx);
  }

  console.log("proposal batch preimage:");
  console.log(
    await generateProposal(getBatch(), admin, [
      {
        asset: 1005,
        symbol: "avDOT",
        address: (await hre.deployments.get("VDOT-AToken-Hydration")).address,
      },
    ])
  );
});
