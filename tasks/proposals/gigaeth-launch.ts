// @ts-nocheck
import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  generateProposal,
  getApi,
  location,
  generateProposalV2,
  dispatchAs,
  rootEvmCall,
  padAddress,
} from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  ZERO_ADDRESS,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { exit } from "process";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import chalk from "chalk";

task(`gigaeth-launch`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const network = FORK ? FORK : (hre.network.name as eNetwork);
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
  const hydrationTx = (await getApi()).tx;
  const gETH = 420;
  const gETHs = 4200;
  const wstETH = 1000809;
  const aETH = 1007;
  const ETH = 34;
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";
  const omnipool = "13UVJyLnPLowAMzbZewu9zwEGiSMQKniJ2cp4vM4ru2nci9N";
  const txs = [];

  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  const chainlinkConf = config.ChainlinkAggregator[network];
  if (!chainlinkConf) {
    console.log(chalk.red(`'${network}': chainlink configuration not found`));
    exit(1);
  }

  console.log("---------> register assets");
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
  let nonce = await hre.ethers.provider.getTransactionCount(deployer);

  console.log("---------> register GETH");
  let agEthToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });
  let reserveAddress = await getReserveAddress(config, "GETH");
  if (agEthToken) {
    const underlying = new hre.ethers.Contract(
      reserveAddress,
      (await hre.deployments.getArtifact("AToken")).abi,
      signer
    );
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: gETH,
          name: "GIGAETH",
          assetType: "Erc20",
          existentialDeposit: 1,
          symbol: "GETH",
          decimals: 18,
          location: location(agEthToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    return Error("GETH ATOKEN DOESNT EXIST");
  }

  console.log("---------> register aETH");
  nonce = await hre.ethers.provider.getTransactionCount(deployer);
  let aEthToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce + 3,
  });
  reserveAddress = await getReserveAddress(config, "ETH");
  if (aEthToken) {
    const underlying = new hre.ethers.Contract(
      reserveAddress,
      (await hre.deployments.getArtifact("AToken")).abi,
      signer
    );
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: aETH,
          name: "aETH",
          assetType: "Erc20",
          existentialDeposit: 0,
          symbol: "aETH",
          decimals: 18,
          location: location(aEthToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    return Error("ETH ATOKEN DOESNT EXIST");
  }

  console.log("---------> register 2-Pool-gETH");
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: gETHs,
        name: "2-Pool-GETH",
        assetType: "StableSwap",
        existentialDeposit: 1,
        symbol: "2-Pool-GETH",
        decimals: 18,
        location: null,
        xcmRateLimit: null,
        isSufficient: true,
      })
    )
  );

  console.log("update rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("init GIGAETH reserve");
  await hre.run("init-reserve", {
    symbol: "GETH",
    batch: true,
  });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("init ETH reserve");
  await hre.run("init-reserve", {
    symbol: "ETH",
    batch: true,
  });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: false, batch: true });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: false, batch: true });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: false, batch: true });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("setup ETH emode");
  await hre.run("review-e-mode", { fix: true, batch: true, name: "StableEMode" });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  console.log("---------> create stableswap pool with pegs");
  const wstEthEthOracle = chainlinkConf.WSTETH_ETH;
  if (!wstEthEthOracle) {
    console.log(
      chalk.red(`'${network}.WSTETH_ETH' oracle's address not found`)
    );
    exit(1);
  }

  console.log("---------> add liquidity to created pool");
  //Create stableswap pool and add liquidity
  txs.push(
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: gETHs,
        assets: [wstETH, aETH],
        amplification: 100,
        fee: 690,
        pegSource: [{ MMOracle: wstEthEthOracle }, { value: [1, 1] }],
        maxPegUpdate: 50000, //TODO:
      })
    )
  );

  //add ETH to mm
  txs.push(
    await dispatchAs(
      treasury,
      hydrationTx.router.sell(
        ...Object.values({
          assetIn: ETH,
          assetOut: aETH,
          amount: "346.500_000_000_000_000_000"
            .replaceAll(".", "")
            .replaceAll("_", ""),
          minAmountOut: 0,
          route: [{ pool: "Aave", assetIn: ETH, assetOut: aETH }],
        })
      )
    )
  );

  txs.push(
    await dispatchAs(
      treasury,
      hydrationTx.stableswap.addLiquidity(
        ...Object.values({
          poolId: gETHs,
          assets: [
            {
              assetId: aETH,
              amount: "346.500_000_000_000_000_000"
                .replaceAll(".", "")
                .replaceAll("_", ""),
            },
            {
              assetId: wstETH,
              amount: "289.310_000_000_000_000_000"
                .replaceAll(".", "")
                .replaceAll("_", ""),
            },
          ],
        })
      )
    )
  );

  //add gETHs to mm
  txs.push(
    await dispatchAs(
      treasury,
      hydrationTx.router.sellAll(
        ...Object.values({
          assetIn: gETHs,
          assetOut: gETH,
          minAmountOut: 0,
          route: [{ pool: "Aave", assetIn: gETHs, assetOut: gETH }],
        })
      )
    )
  );

  //tx asset to omnipool's account
  txs.push(
    await dispatchAs(
      treasury,
      hydrationTx.currencies.transfer(
        ...Object.values({
          dest: omnipool,
          currencyId: gETH,
          amount: "703.149_801_922_654_340_265"
            .replaceAll(".", "")
            .replaceAll("_", ""),
        })
      )
    )
  );

  txs.push(
    hydrationTx.utility.dispatchAs(
      { System: "Root" },
      hydrationTx.omnipool.addToken(
        ...Object.values({
          asset: gETH,
          price: "120_282_396_655_829".replaceAll(".", "").replaceAll("_", ""),
          weightCap: "100_000".replaceAll(".", "").replaceAll("_", ""),
          positionOwner: treasury,
        })
      )
    )
  );

  //allow 420 as fee payment asset
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: gETH,
        price: "408_930_833_153_131_000"
          .replaceAll(".", "")
          .replaceAll("_", ""),
      })
    )
  );

  //allow 4200 as fee payment asset
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: gETHs,
        price: "408_930_833_153_131_000"
          .replaceAll(".", "")
          .replaceAll("_", ""),
      })
    )
  );

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
