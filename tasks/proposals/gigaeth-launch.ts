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
  const wstETH  = 1000809;
  const aETH = 1007;
  const ETH = 34;
  const threasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";
  const txs = [];

  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

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

  const reserveAddress = await getReserveAddress(config, "GETH");
  console.log("reserve", reserveAddress);

  //Deploy aToken and register assets in asset registry
  if (aToken) {
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
          existentialDeposit: 0,
          symbol: "GETH",
          decimals: 18,
          location: location(aToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    console.log("ATOKEN DOESNT EXIST");
    return Error("AToken should be there at this point");
  }

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

  const chainlinkConf = config.ChainlinkAggregator[network];
  if (!chainlinkConf) {
    console.log(
      chalk.red(
        `'${network}': chainlink configuration not found`
      )
    );
    exit(1);
  }

  const wstEthOracle = chainlinkConf.WSTETH;
  if (!wstEthOracle) {
    console.log(
      chalk.red(
        `'${network}.WSTETH' oracle's address not found`
      )
    );
    exit(1);
  }
  const ethOracle = chainlinkConf.ETH;
  if (!ethOracle) {
    console.log(
      chalk.red(
        `'${network}.ETH' oracle's address not found`
      )
    );
    exit(1);
  }

  //Create stableswap pool and add liquidity
  txs.push(
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: gETHs,
        assets: [wstETH, aETH],
        amplification: 100,
        fee: 690, //TODO:
        pegSource: [{ MMOracle: wstEthOracle }, { MMOracle: ethOracle }],
        maxPegUpdate: 10000, //TODO:  
      })
    )
  );

  txs.push(
    await dispatchAs(
      threasury,
      hydrationTx.stableswap.addLiquidity(
        ...Object.values({
          poolId: gETHs,
          assets: [
            { assetId: aETH, amount: "346.500_000_000_000_000_000".replaceAll(".", "").replaceAll("_", "") },
            { assetId: wstETH, amount: "288.200_000_000_000_000_000".replaceAll(".", "").replaceAll("_", "") }, 
          ],
        })
      )
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

  //add gETHs to mm
  txs.push(
    await dispatchAs(
      threasury,
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


  //TODO: INCENTIVES
  // await hre.run("review-emission-admin", { batch: true, reserve: "GDOT" });
  // for await (const el of getBatch()) {
  //   el.from = admin;
  //   txs.push(await rootEvmCall(el));
  // }
  // clearBatch();
  // await hre.run("review-incentive", {
  //   batch: true,
  //   reserve: "GDOT",
  //   incentivize: aToken,
  // });
  // for await (const el of getBatch()) {
  //   el.from = admin;
  //   txs.push(
  //     hydrationTx.scheduler.scheduleAfter(
  //       ...Object.values({
  //         after: 2,
  //         maybePeriodic: null,
  //         priority: 0,
  //         call: await rootEvmCall(el),
  //       })
  //     )
  //   );
  // }
  // clearBatch();
  //
  //send rewards to pot
  // const rewardsPot = (await getPotRewardsStrategy())?.address;
  // if (!rewardsPot || rewardsPot == ZERO_ADDRESS) {
  //   console.log(rewardsPot);
  //   console.log(chalk.red(`failed to get rewrds pot address or is not valid`));
  //   exit(1);
  // }
  // //Transfer rewards to pot
  // txs.push(
  //   await dispatchAs(
  //     threasury,
  //     hydrationTx.currencies.transfer(
  //       ...Object.values({
  //         dest: padAddress(rewardsPot),
  //         currencyId: gDOT,
  //         amount: "26,640.000,000,000,000,000,000"
  //           .replaceAll(",", "")
  //           .replaceAll(".", ""),
  //       })
  //     )
  //   )
  // );

  //TODO: allow 69 as fee payment asset
  // txs.push(
  //   hydrationTx.multiTransactionPayment.addCurrency(
  //     ...Object.values({
  //       asset: gDOT,
  //       price: "302571428571429000000",
  //     })
  //   )
  // );
  //
  // //allow 690 as fee payment asset
  // txs.push(
  //   hydrationTx.multiTransactionPayment.addCurrency(
  //     ...Object.values({
  //       asset: gDOTs,
  //       price: "302571428571429000000",
  //     })
  //   )
  // );

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
