// @ts-nocheck
import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  getApi,
  location,
  generateProposalV2,
  dispatchAs,
  padAddress,
  aaveManagerCall,
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
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { exit } from "process";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import chalk from "chalk";

task(
  `heurc-launch`,
  `Generate HEURC (aEURC/HOLLAR) stablepool launch governance proposal`
).setAction(async function (_, hre) {
  const { utils, constants } = hre.ethers;
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
  const hydrationApi = await getApi();
  const hydrationTx = hydrationApi.tx;

  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  const network = FORK ? FORK : hre.network.name;
  const chainlinkConf = config.ChainlinkAggregator[network];
  if (!chainlinkConf) {
    console.log(
      chalk.red(`'${network}': chainlink configuration not found`)
    );
    exit(1);
  }

  // ===== Asset IDs =====
  const EURC = 44; // EURC asset ID on Hydration (already registered on chain)
  const aEURC_ID = 1044; // aEURC (Aave deposit token for EURC)
  const HEURC_ID = 4444; // HEURC ERC20 aToken (receipt for depositing 2-Pool-HEURC)
  const HEURC_POOL = 10044; // 2-Pool-HEURC stableswap LP token
  const HOLLAR = 222; // HOLLAR stablecoin
  const heurcReserveName = "2-POOL-HEURC";

  // EUR/USD DIA oracle — read from ChainlinkAggregator config (same address used for EURC price feed)
  const eurUsdOracle = chainlinkConf["EURUSD"];
  if (!eurUsdOracle || eurUsdOracle === constants.AddressZero) {
    console.log(chalk.red("error: EURUSD oracle not configured in ChainlinkAggregator"));
    exit(1);
  }

  const heurcOracle = chainlinkConf[heurcReserveName];
  if (!heurcOracle || heurcOracle === constants.AddressZero) {
    console.log(chalk.red(`error: oracle for '${heurcReserveName}' not configured in ChainlinkAggregator`));
    exit(1);
  }

  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  const txs = [];
  const last = [];

  // ===== Register assets in Hydration asset registry =====
  console.log("---------> register assets");
  let deployerAddress;
  try {
    deployerAddress =
      config.ATokensAndRatesHelper ||
      (await hre.deployments.get("ATokensAndRatesHelper")).address;
  } catch (error) {
    deployerAddress = await poolAddressesProvider.getPoolConfigurator();
  }
  console.log("Deployer Address:", deployerAddress);
  const deployerNonce =
    await hre.ethers.provider.getTransactionCount(deployerAddress);

  // 1. Register aEURC (1044) — aToken for EURC reserve (deployed at nonce+0 by init-reserve)
  const aEurcToken = utils.getContractAddress({
    from: deployerAddress,
    nonce: deployerNonce,
  });
  console.log("---------> register aEURC (1044) at", aEurcToken);
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: aEURC_ID,
        name: "aEURC",
        assetType: "Erc20",
        existentialDeposit: "17241",
        symbol: "aEURC",
        decimals: 6,
        location: location(aEurcToken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    )
  );

  // 2. Register HEURC (4444) — aToken for 2-Pool-HEURC reserve
  // EURC init-reserve deploys: aToken(nonce+0), vToken(nonce+1), sToken(nonce+2)
  // → HEURC aToken appears at nonce+3
  const heurcToken = utils.getContractAddress({
    from: deployerAddress,
    nonce: deployerNonce + 3,
  });
  console.log("---------> register HEURC (4444) at", heurcToken);
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: HEURC_ID,
        name: "Hydrated EURC",
        assetType: "Erc20",
        existentialDeposit: "17241379310344828",
        symbol: "HEURC",
        decimals: 18,
        location: location(heurcToken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    )
  );

  // 3. Register 2-Pool-HEURC (10044) — stableswap LP token
  console.log("---------> register 2-Pool-HEURC (10044)");
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: HEURC_POOL,
        name: "2-Pool-HEURC",
        assetType: "StableSwap",
        existentialDeposit: "17241379310344828",
        symbol: "2-Pool-HEURC",
        decimals: 18,
        location: null,
        xcmRateLimit: utils.parseEther("1500000").toString(),
        isSufficient: true,
      })
    )
  );

  // ===== Initialize Aave reserves =====
  // ChainlinkAggregator["2-POOL-HEURC"] must already point to the deployed USDOracleAdapter.
  // init-reserve reads from ChainlinkAggregator, so the oracle is set correctly from the start.
  console.log("review rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  console.log("init EURC reserve");
  await hre.run("init-reserve", {
    symbol: "EURC",
    batch: true,
  });

  console.log("init 2-POOL-HEURC reserve");
  await hre.run("init-reserve", {
    symbol: heurcReserveName,
    batch: true,
  });

  for (const reserve of ["EURC", heurcReserveName]) {
    console.log(`update reserve configs for ${reserve}`);
    await hre.run("review-reserve-configs", {
      fix: false,
      batch: true,
      only: reserve,
    });

    console.log(`update supply caps for ${reserve}`);
    await hre.run("review-supply-caps", {
      fix: false,
      batch: true,
      checkOnly: reserve,
    });

    console.log(`update borrow caps for ${reserve}`);
    await hre.run("review-borrow-caps", {
      fix: false,
      batch: true,
      checkOnly: reserve,
    });
  }

  // Flush all batched EVM calls (init-reserve, configs)
  for (const el of getBatch()) {
    el.from = admin;
    txs.push(await aaveManagerCall(el));
  }
  clearBatch();

  // ===== Set EUROZONE eMode category (id=5) =====
  // Deferred to later block via addTransaction so reserves are fully committed first
  console.log("---------> set EUROZONE eMode");
  {
    const tx = await poolConfigurator.populateTransaction.setEModeCategory(
      5, 8000, 8500, 10300, constants.AddressZero, "EUROZONE"
    );
    tx.from = admin;
    tx.gasLimit = 400000;
    addTransaction(tx, "setEModeCategory EUROZONE (id=5)");
  }
  {
    const eurcAddr = config.ReserveAssets[network]["EURC"];
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(eurcAddr, 5);
    tx.from = admin;
    tx.gasLimit = 100000;
    addTransaction(tx, "setAssetEModeCategory EURC → eMode 5");
  }
  {
    const heurcPoolAddr = config.ReserveAssets[network][heurcReserveName];
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(heurcPoolAddr, 5);
    tx.from = admin;
    tx.gasLimit = 100000;
    addTransaction(tx, "setAssetEModeCategory 2-POOL-HEURC → eMode 5");
  }

  // ===== Create stableswap pool with drifting peg =====
  // Pool: aEURC(1044) + HOLLAR(222), LP token = 2-Pool-HEURC(10044)
  // HOLLAR pegged 1:1 (base), aEURC drifts with EUR/USD oracle
  console.log("---------> create stableswap pool with pegs");
  txs.push(
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: HEURC_POOL,
        assets: [HOLLAR, aEURC_ID], // Sorted by asset ID: HOLLAR(222) < aEURC(1044)
        amplification: 50,
        fee: 500, // 0.05% fee
        pegSource: [
          { value: [1, 1] }, // HOLLAR: fixed 1:1 peg (base reference)
          { MMOracle: eurUsdOracle }, // aEURC: drifting peg via EUR/USD DIA oracle
        ],
        maxPegUpdate: 10000, // EUR/USD peg update (0.6%/h, 14.4%/day)
      })
    )
  );

  // ===== Fee payment registration =====
  console.log("---------> register fee payment assets");
  const aEurcFeePrice   = "2576530612";
  const heurcATokenPrice = "1915517241379310000000";
  const heurcLPPrice     = "1915517241379310000000";

  // Allow aEURC (1044) as fee payment asset
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: aEURC_ID, price: aEurcFeePrice })
    )
  );

  // Allow HEURC (4444) as fee payment asset
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: HEURC_ID, price: heurcATokenPrice })
    )
  );

  // Allow 2-Pool-HEURC (10044) LP token as fee payment asset
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: HEURC_POOL, price: heurcLPPrice })
    )
  );

  // ===== Incentives setup =====
  console.log("---------> setup incentives");
  await hre.run("review-emission-admin", {
    batch: true,
    reserve: heurcReserveName,
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: heurcReserveName,
    incentivize: heurcToken,
  });

  // Transfer gDOT rewards to PotRewardsStrategy directly from treasury
  console.log("transfer incentives to the pot");
  const pot = padAddress((await getPotRewardsStrategy())?.address);
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.currencies.transfer(
        pot,
        69, // gDOT reward token
        utils.parseEther("16000").toString() // 16000 gDOT over ~2 months
      )
    )
  );

  // ===== Seed initial liquidity from treasury =====
  console.log("---------> seed initial liquidity");
  const eurcAmount = utils.parseUnits("215150", 6).toString(); // 215,150 EURC (6 decimals)
  const hollarAmount = utils.parseEther("250000").toString(); // 250,000 HOLLAR (18 decimals)

  // Treasury swaps EURC → aEURC via Aave
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.router.sell(
        ...Object.values({
          assetIn: EURC,
          assetOut: aEURC_ID,
          amount: eurcAmount,
          minAmountOut: 0,
          route: [{ pool: "Aave", assetIn: EURC, assetOut: aEURC_ID }],
        })
      )
    )
  );

  // Treasury adds aEURC + HOLLAR as liquidity to stableswap pool
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.stableswap.addAssetsLiquidity(
        ...Object.values({
          poolId: HEURC_POOL,
          assets: [
            {
              assetId: HOLLAR, // Sorted: HOLLAR(222) first
              amount: hollarAmount,
            },
            {
              assetId: aEURC_ID, // aEURC(1044) second
              amount: eurcAmount,
            },
          ],
          minShares: 0, // No slippage protection for initial liquidity
        })
      )
    )
  );

  // Treasury wraps LP tokens → HEURC (supply 2-Pool-HEURC to Aave)
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.router.sellAll(
        ...Object.values({
          assetIn: HEURC_POOL,
          assetOut: HEURC_ID,
          minAmountOut: 0,
          route: [
            { pool: "Aave", assetIn: HEURC_POOL, assetOut: HEURC_ID },
          ],
        })
      )
    )
  );

  // Treasury DCA: EURC → HEURC (8,666.666666 EURC/period × 3 orders = 26,000 EURC total)
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.dca.schedule(
        ...Object.values({
          schedule: {
            owner: treasury,
            period: 6,
            maxRetries: { Some: 5 },
            totalAmount: utils.parseUnits("26000", 6).toString(),
            slippage: 30000,
            order: {
              Sell: {
                assetIn: EURC,
                assetOut: HEURC_ID,
                amountIn: utils.parseUnits("8666.666666", 6).toString(),
                minAmountOut: "9677649718102442203705",
                route: [
                  { pool: { Aave: null }, assetIn: EURC, assetOut: aEURC_ID },
                  { pool: { Stableswap: HEURC_POOL }, assetIn: aEURC_ID, assetOut: HEURC_POOL },
                  { pool: { Aave: null }, assetIn: HEURC_POOL, assetOut: HEURC_ID },
                ],
              },
            },
          },
          startExecutionBlock: null,
        })
      )
    )
  );

  // ===== Schedule deferred transactions =====
  // Incentive EVM calls need reserves to be initialized first
  const later = [];
  for (const el of getBatch()) {
    el.from = admin;
    later.push(await aaveManagerCall(el));
  }

  if (later.length > 0) {
    txs.push(
      hydrationTx.scheduler.scheduleAfter(
        0,
        null,
        0,
        hydrationTx.utility.batchAll(later)
      )
    );
  }

  // Liquidity seeding + incentive transfer after pool creation
  txs.push(
    hydrationTx.scheduler.scheduleAfter(
      1,
      null,
      0,
      hydrationTx.utility.batchAll(last)
    )
  );

  // ===== Generate proposal =====
  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
