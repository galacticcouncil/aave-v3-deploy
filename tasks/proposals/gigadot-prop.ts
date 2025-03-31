// @ts-nocheck
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

task(`gigadot-prop`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
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

  console.log("init GIGADOT reserve");
  await hre.run("init-reserve", {
    symbol: "GIGADOT",
    batch: true,
  });

  console.log("update rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: true, batch: true });

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: true, batch: true });

  console.log("register tokens");
  const registerTokens = [];

  let deployer;
  try {
    deployer = config.ATokensAndRatesHelper || 
      (await hre.deployments.get("ATokensAndRatesHelper")).address;
  } catch (error) {
    // If not found, use the PoolConfigurator
    deployer = await poolAddressesProvider.getPoolConfigurator();
  }
  console.log("Deployer Address:", deployer);

  const nonce = await hre.ethers.provider.getTransactionCount(deployer);

  let aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce
  });
  console.log("aToken", aToken);

  const reserveAddress = await getReserveAddress(config, "GIGADOT");
  console.log("reserve", reserveAddress)
  if (aToken) {
    const underlying = new hre.ethers.Contract(
      reserveAddress,
      (await hre.deployments.getArtifact("AToken")).abi,
      signer
    );
    const decimals = await underlying.callStatic.decimals();
    const token = {
      asset: 1007,
      symbol: "agigaDOT",
      address: aToken,
      decimals: 10,
    };
    console.log("adding", token);
    registerTokens.push(token);
  } else {
    console.log("ATOKEN DOESNT EXIST")
    return Error("AToken should be there at this point")
  }

  //TODO: incentives setup

  console.log("proposal batch preimage:");
  console.log(
    (await generateProposal(getBatch(), admin, registerTokens)).toHex()
  );
});
