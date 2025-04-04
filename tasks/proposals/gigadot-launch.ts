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
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`gigadot-launch`, ``).setAction(async function (_, hre) {
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
    symbol: "GDOT",
    batch: true,
  });

  console.log("update rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: false, batch: true });

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: false, batch: true });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: false, batch: true });

  console.log("register tokens");
  const registerTokens = [];

  let deployer;
  try {
    deployer =
      config.ATokensAndRatesHelper ||
      (await hre.deployments.get("ATokensAndRatesHelper")).address;
  } catch (error) {
    // If not found, use the PoolConfigurator
    deployer = await poolAddressesProvider.getPoolConfigurator();
  }
  console.log("Deployer Address:", deployer);

  const nonce = await hre.ethers.provider.getTransactionCount(deployer);

  let aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });
  console.log("aToken", aToken);

  const reserveAddress = await getReserveAddress(config, "GDOT");
  console.log("reserve", reserveAddress);

  const gDOT = 69;
  const gDOTs = 690;
  if (aToken) {
    const underlying = new hre.ethers.Contract(
      reserveAddress,
      (await hre.deployments.getArtifact("AToken")).abi,
      signer
    );
    const token = {
      asset: gDOT,
      symbol: "GDOT",
      address: aToken,
      decimals: 18,
      name: "gigaDOT",
      existentialDeposit: 0,
    };
    console.log("adding", token);
    registerTokens.push(token);
  } else {
    console.log("ATOKEN DOESNT EXIST");
    return Error("AToken should be there at this point");
  }

  //incentives
  await hre.run("review-emission-admin", { batch: true, reserve: "GDOT" });
  await hre.run("review-incentive", {
    batch: true,
    reserve: "GDOT",
    reserveAddress: aToken,
  });

  //gigaDOT pool
  registerTokens.push({
    asset: gDOTs,
    name: "2-Pool-GDOT",
    symbol: "2-Pool-GDOT",
    assetType: "StableSwap",
    existentialDeposit: 1,
    address: null,
    decimals: 18,
  });

  const vDOT = 15;
  const aDOT = 1001;

  const createPoolWithPegs = [
    {
      shareAsset: gDOTs,
      assets: [vDOT, aDOT],
      amplification: 22,
      fee: 690,
      pegSource: [{ oracle: ["bifrosto", 0, 5] }, { value: [1, 1] }],
      maxPegUpdate: 1000000,
    },
  ];
  const addLiquidity = [
    {
      origin: "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh",
      poolId: gDOTs,
      assets: [
        { assetId: vDOT, amount: "608191293362092" },
        { assetId: aDOT, amount: "1000000000000000" },
      ],
    },
  ];

  let preimages = await generateProposal(
    getBatch(),
    admin,
    registerTokens,
    false,
    [],
    [],
    createPoolWithPegs,
    addLiquidity
  );

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimages.toHex());
  decoder.printTree(decoder.transformCall(preimages.toHuman()));
});
