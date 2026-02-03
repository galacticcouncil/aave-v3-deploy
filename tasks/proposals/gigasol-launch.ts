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
  evm,
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
  ZERO_ADDRESS,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { exit } from "process";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import chalk from "chalk";

task(`gigasol-launch`, `Generate GIGASOL launch governance proposal`).setAction(
  async function (_, hre) {
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

    // Asset IDs - Verified from Hydration chain
    const gSOLReserveName = "2-POOL-GSOL";
    const gSOL = 9001; // GIGASOL aToken asset ID (receipt for depositing 2-Pool-GSOL)
    const gSOLs = 901; // 2-Pool-GSOL stableswap LP token asset ID
    const jitoSOL = 40; // jitoSOL asset ID on Hydration
    const aSOL = 1009; // aSOL (Aave deposit token for SOL) - next available after a3-Pool(1008)
    const SOL = 1000752; // SOL asset ID (bridged via MRL/Wormhole)
    const VDOT = 15;
    const LRNA = 1;
    const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";
    const omnipool = "13UVJyLnPLowAMzbZewu9zwEGiSMQKniJ2cp4vM4ru2nci9N";
    const txs = [];

    if (!isPoolAdmin) {
      console.error("not pool admin " + admin);
      return;
    }

    const chainlinkConf = config.ChainlinkAggregator[network];
    if (!chainlinkConf) {
      console.log(
        chalk.red(`'${network}': chainlink configuration not found`)
      );
      exit(1);
    }

    // --- Register assets ---
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

    // add 2-Pool-GSOL to MM (register as GIGASOL)
    console.log("---------> register GSOL (GIGASOL aToken)");
    let agSolToken = utils.getContractAddress({
      from: deployer,
      nonce: nonce,
    });
    let reserveAddress = await getReserveAddress(config, gSOLReserveName);
    if (agSolToken) {
      const underlying = new hre.ethers.Contract(
        reserveAddress,
        (await hre.deployments.getArtifact("AToken")).abi,
        signer
      );
      // Register GIGASOL (gSOL) in asset registry
      txs.push(
        hydrationTx.assetRegistry.register(
          ...Object.values({
            id: gSOL,
            name: "GIGASOL",
            assetType: "Erc20",
            existentialDeposit: "1_000_000_000" // 1 SOL in lamports (9 decimals)
              .replaceAll(".", "")
              .replaceAll("_", ""),
            symbol: "GSOL",
            decimals: 18,
            location: location(agSolToken),
            xcmRateLimit: null,
            isSufficient: true,
          })
        )
      );
    } else {
      return Error("GSOL ATOKEN DOESNT EXIST");
    }

    // add SOL to the MM (register as aSOL)
    console.log("---------> register aSOL");
    nonce = await hre.ethers.provider.getTransactionCount(deployer);
    let aSolToken = utils.getContractAddress({
      from: deployer,
      nonce: nonce + 3,
    });
    reserveAddress = await getReserveAddress(config, "SOL");
    if (aSolToken) {
      const underlying = new hre.ethers.Contract(
        reserveAddress,
        (await hre.deployments.getArtifact("AToken")).abi,
        signer
      );
      // Register aSOL (Aave SOL deposit token) in asset registry
      txs.push(
        hydrationTx.assetRegistry.register(
          ...Object.values({
            id: aSOL,
            name: "aSOL",
            assetType: "Erc20",
            existentialDeposit: "1_000_000_000" // 1 SOL in lamports (9 decimals)
              .replaceAll(".", "")
              .replaceAll("_", ""),
            symbol: "aSOL",
            decimals: 9, // SOL has 9 decimals
            location: location(aSolToken),
            xcmRateLimit: null,
            isSufficient: true,
          })
        )
      );
    } else {
      return Error("SOL ATOKEN DOESNT EXIST");
    }

    // Register 2-Pool-GSOL (stableswap LP token) in asset registry
    console.log("---------> register 2-Pool-GSOL");
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: gSOLs,
          name: "2-Pool-GSOL",
          assetType: "StableSwap",
          existentialDeposit: 1000,
          symbol: "2-Pool-GSOL",
          decimals: 18,
          location: null,
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );

    // --- Initialize reserves in MM ---
    console.log("update rate strategies");
    await hre.run("review-rate-strategies", {
      deploy: true,
      fix: true,
      batch: true,
    });

    console.log("init GIGASOL reserve");
    await hre.run("init-reserve", {
      symbol: gSOLReserveName,
      batch: true,
    });

    console.log("init SOL reserve");
    await hre.run("init-reserve", {
      symbol: "SOL",
      batch: true,
    });

    console.log("update reserve configs");
    await hre.run("review-reserve-configs", { fix: false, batch: true });

    console.log("update supply caps");
    await hre.run("review-supply-caps", { fix: false, batch: true });

    console.log("update borrow caps");
    await hre.run("review-borrow-caps", { fix: false, batch: true });

    console.log("setup SOL emode");
    await hre.run("review-e-mode", { fix: true, batch: true, name: "SolEMode" });

    console.log("add SOL to SOL emode");
    {
      const tx =
        await poolConfigurator.populateTransaction.setAssetEModeCategory(
          await getReserveAddress(config, "SOL"),
          config.EModes["SolEMode"].id
        );
      addTransaction(tx);
    }

    console.log("add GSOL to SOL emode");
    {
      const tx =
        await poolConfigurator.populateTransaction.setAssetEModeCategory(
          await getReserveAddress(config, gSOLReserveName),
          config.EModes["SolEMode"].id
        );
      addTransaction(tx);
    }
    for await (const el of getBatch()) {
      el.from = admin;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // --- create pegged stableswap pool with jitoSOL & aSOL ---
    // PREREQUISITE: JITOSOL_SOL oracle and 2-POOL-GSOL USDOracleAdapter must be deployed first
    console.log("---------> create stableswap pool with pegs");
    const jitoSolSolOracle = chainlinkConf.JITOSOL_SOL;
    if (!jitoSolSolOracle || jitoSolSolOracle === ZERO_ADDRESS) {
      console.log(
        chalk.red(
          `'${network}.JITOSOL_SOL' oracle's address not found or not deployed yet`
        )
      );
      console.log(
        chalk.yellow(`Please deploy the jitoSOL/SOL oracle first using:`)
      );
      console.log(
        chalk.yellow(`  npx hardhat deploy-jitoSOLOracle --network ${network}`)
      );
      exit(1);
    }

    const gsolOracle = chainlinkConf["2-POOL-GSOL"];
    if (!gsolOracle || gsolOracle === ZERO_ADDRESS) {
      console.log(
        chalk.red(
          `'${network}.2-POOL-GSOL' oracle's address not found or not deployed yet`
        )
      );
      console.log(
        chalk.yellow(`Please deploy the USDOracleAdapter first using:`)
      );
      console.log(
        chalk.yellow(`  MARKET_NAME=Hydration npx hardhat deploy-USDOracleAdapter --oracle 2-POOL-GSOL --network ${network}`)
      );
      exit(1);
    }

    // Set jitoSOL/SOL oracle price (update to current rate before running proposal)
    // Get current rate from: node helpers/get-jitosol-ratio.js
    console.log("set jitoSOL/SOL oracle price");
    await hre.run("set-oracle-price", {
      oracle: jitoSolSolOracle,
      price: "125672373", // ~1.2567 jitoSOL/SOL - update before proposal execution
    });
    // Batch oracle price update calls
    for await (const el of getBatch()) {
      el.from = admin;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // Create stableswap pool 2-Pool-GSOL with jitoSOL & aSOL, with pegs
    txs.push(
      hydrationTx.stableswap.createPoolWithPegs(
        ...Object.values({
          shareAsset: gSOLs,
          assets: [jitoSOL, aSOL], // Sorted by asset ID: jitoSOL(40) < aSOL(1009)
          amplification: 100,
          fee: 690, // 0.069% fee
          pegSource: [
            { MMOracle: jitoSolSolOracle }, // jitoSOL uses oracle for drifting peg
            { value: [1, 1] }, // aSOL pegged 1:1 to SOL
          ],
          maxPegUpdate: 3, // 3 Perbill per block (~1.6% max drift per year)
        })
      )
    );

    //TODO: fix it with correct values, ask Ben
    // --- Initial liquidity from treasury ---
    const initialSolAmount = "250_000_000_000" // 804 SOL (9 decimals)
      .replaceAll(".", "")
      .replaceAll("_", "");
    const initialJitoSolAmount = "300_000_000_000" // 640 jitoSOL (9 decimals)
      .replaceAll(".", "")
      .replaceAll("_", "");

    // Add SOL to money market (treasury sells SOL for aSOL)
    txs.push(
      await dispatchAs(
        treasury,
        hydrationTx.router.sell(
          ...Object.values({
            assetIn: SOL,
            assetOut: aSOL,
            amount: initialSolAmount,
            minAmountOut: 0,
            route: [{ pool: "Aave", assetIn: SOL, assetOut: aSOL }],
          })
        )
      )
    );

    // Transfer aSOL from treasury to omnipool
    txs.push(
      await dispatchAs(
        treasury,
        hydrationTx.currencies.transfer(
          ...Object.values({
            dest: omnipool,
            currencyId: aSOL,
            amount: initialSolAmount,
          })
        )
      )
    );

    // Transfer jitoSOL from treasury to omnipool
    txs.push(
      await dispatchAs(
        treasury,
        hydrationTx.currencies.transfer(
          ...Object.values({
            dest: omnipool,
            currencyId: jitoSOL,
            amount: initialJitoSolAmount,
          })
        )
      )
    );

    // Add liquidity to stableswap pool (omnipool adds jitoSOL + aSOL)
    txs.push(
      await dispatchAs(
        omnipool,
        hydrationTx.stableswap.addAssetsLiquidity(
          ...Object.values({
            poolId: gSOLs,
            assets: [
              {
                assetId: jitoSOL, // Sorted by asset ID: jitoSOL(40) first
                amount: initialJitoSolAmount,
              },
              {
                assetId: aSOL, // aSOL(1009) second
                amount: initialSolAmount,
              },
            ],
            minShares: 0, // No slippage protection for initial liquidity
          })
        )
      )
    );

    // Add LP tokens (gSOLs) to money market to get GIGASOL (gSOL)
    txs.push(
      await dispatchAs(
        omnipool,
        hydrationTx.router.sellAll(
          ...Object.values({
            assetIn: gSOLs,
            assetOut: gSOL,
            minAmountOut: 0,
            route: [{ pool: "Aave", assetIn: gSOLs, assetOut: gSOL }],
          })
        )
      )
    );

    // --- add GIGASOL to the Omnipool ---
    // TODO: DOUBLE CHECK PRICE BEFORE PROPOSAL EXECUTION
    const omnipoolPrice = "10_925_768_823_966"
      .replaceAll(".", "")
      .replaceAll("_", "");

    // Add GIGASOL to Omnipool
    txs.push(
      hydrationTx.omnipool.addToken(
        ...Object.values({
          asset: gSOL,
          price: omnipoolPrice,
          weightCap: "100_000".replaceAll(".", "").replaceAll("_", ""),
          positionOwner: treasury,
        })
      )
    );

    // --- Enable as fee payment asset ---
    const feePaymentPrice = "30_776_699_029_126_213_592"
      .replaceAll(".", "")
      .replaceAll("_", "");

    // Allow gSOL (GIGASOL) as fee payment asset
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({
          asset: gSOL,
          price: feePaymentPrice,
        })
      )
    );

    // Allow gSOLs (2-Pool-GSOL LP token) as fee payment asset
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({
          asset: gSOLs,
          price: feePaymentPrice,
        })
      )
    );

    // --- setup incentives on 2-Pool-GSOL supply in MM ---
    console.log("---------> setup liquidity mining");
    txs.push(
      hydrationTx.omnipoolLiquidityMining.createGlobalFarm(
        ...Object.values({
          totalRewards: "20,000,000,000,000,000,000,000".replaceAll(",", ""),
          plannedYieldingPeriods: 1718308,
          blocksPerPeriod: 1,
          rewardCurrecny: 69,
          owner: treasury,
          yieldPerPeriod: "131,278,538,813".replaceAll(",", ""),
          minDeposit: "902,527,075,812".replaceAll(",", ""),
          lrnaPriceAdjustment: "5,624,365,482,233,500,000,000,000".replaceAll(
            ",",
            ""
          ),
        })
      )
    );

    txs.push(
      await dispatchAs(
        treasury,
        hydrationTx.omnipoolLiquidityMining.createYieldFarm(
          ...Object.values({
            globalFarmId: 100, // Next farm ID after GIGAETH (99)
            assetId: gSOL,
            multiplier: "1,000,000,000,000,000,000".replaceAll(",", ""),
            loyaltyCurve: {
              initialRewardPercentage: "500,000,000,000,000,000".replaceAll(
                ",",
                ""
              ),
              scaleCoef: 12000,
            },
          })
        )
      )
    );

    let preimage = await generateProposalV2(txs, false);
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    console.log("submit preimages:");
    console.log(preimage.toHex());
    decoder.printTree(decoder.transformCall(preimage.toHuman()));
  }
);
