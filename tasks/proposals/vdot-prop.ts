import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { generateProposal } from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction, getBatch } from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  ZERO_ADDRESS,
} from "../../helpers";
import { network } from "hardhat";

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

  console.log("update stables emode");
  await hre.run("review-e-mode", {
    name: "StableEMode",
    fix: true,
    batch: true,
  });

  console.log("update DOT emode");
  await hre.run("review-e-mode", {
    name: "DotEMode",
    fix: true,
    batch: true,
  });

  console.log("add VDOT to DOT emode");
  {
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(
      await getReserveAddress(config, "VDOT"),
      config.EModes["DotEMode"].id
    );
    addTransaction(tx);
  }

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: true, batch: true });

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: true, batch: true });

  console.log("register tokens");
  const registerTokens = [];
  const aToken = (await hre.deployments.getOrNull("VDOT-AToken-Hydration"))
    ?.address;
  const reserveAddress = await getReserveAddress(config, "VDOT");
  if (aToken) {
    const underlying = new hre.ethers.Contract(
      reserveAddress,
      (await hre.deployments.getArtifact("AToken")).abi,
      signer
    );
    const decimals = await underlying.callStatic.decimals();
    const token = {
      asset: 1005,
      symbol: "avDOT",
      address: aToken,
      decimals: decimals,
    };
    console.log("adding", token);
    registerTokens.push(token);
  }

  console.log("proposal batch preimage:");
  console.log(
    (await generateProposal(getBatch(), admin, registerTokens)).toHex()
  );
});
