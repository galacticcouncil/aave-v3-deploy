// @ts-nocheck
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
  dispatchAs,
  padAddress,
  evmAddress,
  rootEvmCall,
} from "../../helpers/hydration-proposal.js";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import {
  getPool,
  getPoolAddressesProvider,
  MAX_UINT_AMOUNT,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`hollar-pools-launch`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;
  let deployer = await poolAddressesProvider.getPoolConfigurator();
  let nonce = await hre.ethers.provider.getTransactionCount(deployer);

  const txs = [];
  const last = [];
  const reserves = [
    "2-POOL-HUSDC",
    "2-POOL-HUSDT",
    "2-POOL-HUSDS",
    "2-POOL-HUSDE",
  ];
  const assetIds = [1110, 1111, 1112, 1113];
  const symbols = ["HUSDC", "HUSDT", "HUSDS", "HUSDe"];
  // const pegs = [1, 1, 1.06773195, 1.1979992];
  const displayNames = [
    "Hydrated USDC",
    "Hydrated Tether",
    "Hydrated USDS",
    "Hydrated USDe",
  ];

  // Initialize all reserves
  for (let i = 0; i < reserves.length; i++) {
    console.log(`init ${reserves[i]} reserve`);
    await hre.run("init-reserve", {
      symbol: reserves[i],
      batch: true,
    });
  }

  // Process each reserve
  for (let i = 0; i < reserves.length; i++) {
    console.log("update reserve configs");
    await hre.run("review-reserve-configs", {
      fix: false,
      batch: true,
      only: reserves[i],
    });

    console.log("update supply caps");
    await hre.run("review-supply-caps", {
      fix: false,
      batch: true,
      checkOnly: reserves[i],
    });

    console.log("update borrow caps");
    await hre.run("review-borrow-caps", {
      fix: false,
      batch: true,
      checkOnly: reserves[i],
    });
  }

  for (const el of getBatch()) {
    el.from = POOL_ADMIN[hre.network.name];
    txs.push(await aaveManagerCall(el));
  }
  clearBatch();

  // Register each aToken in Hydration asset registry
  for (let i = 0; i < reserves.length; i++) {
    let atoken = utils.getContractAddress({
      from: deployer,
      nonce: nonce + 3 * i, // 3x because each reserve deploys atoken, vtoken and stoken
    });

    console.log(`register ${reserves[i]} atoken`);
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: assetIds[i],
          name: displayNames[i],
          assetType: "Erc20",
          existentialDeposit: utils.parseEther("0.033").toString(),
          symbol: symbols[i],
          decimals: 18,
          location: location(atoken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );

    // Add aToken as fee payment asset
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({
          asset: assetIds[i],
          price: "11,190,000,000,000,000,000,000".replace(/,/g, ""),
        })
      )
    );

    // Add routing for aToken
    txs.push(
      hydrationTx.router.forceInsertRoute(
        ...Object.values({
          assetPair: {
            assetIn: 0,
            assetOut: assetIds[i],
          },
          newRoute: [
            {
              pool: "Omnipool",
              assetIn: 0,
              assetOut: 102,
            },
            {
              pool: {
                Stableswap: 102,
              },
              assetIn: 102,
              assetOut: 10,
            },
            {
              pool: "Aave",
              assetIn: 10,
              assetOut: 1002,
            },
            {
              pool: {
                Stableswap: 110 + i,
              },
              assetIn: 1002,
              assetOut: 110 + i,
            },
            {
              pool: "Aave",
              assetIn: 110 + i,
              assetOut: assetIds[i],
            },
          ],
        })
      )
    );

    await hre.run("review-emission-admin", {
      batch: true,
      reserve: reserves[i],
    });

    await hre.run("review-incentive", {
      batch: true,
      reserve: reserves[i],
      incentivize: atoken,
    });

    let share = 110 + i;
    let wrapped = share + 1000;
    // supply shares to MM
    last.push(
      await dispatchAs(
        treasury,
        await hydrationTx.router.sellAll(share, wrapped, 0, [
          { pool: "Aave", assetIn: share, assetOut: wrapped },
        ])
      )
    );

    // buy HOLLAR with shares via DCA
    const amountIn = 20;
    const totalAmount = 250000;
    last.push(
      await dispatchAs(
        treasury,
        hydrationTx.dca.schedule(
          {
            owner: treasury,
            period: "40",
            totalAmount: utils.parseEther(totalAmount.toString()).toString(),
            maxRetries: "22",
            stabilityThreshold: null,
            slippage: "30000",
            order: {
              Buy: {
                assetIn: wrapped,
                assetOut: "222",
                amountOut: utils.parseEther("20").toString(),
                maxAmountIn: utils.parseEther(amountIn.toString()).toString(),
                route: [
                  {
                    pool: "Aave",
                    assetIn: wrapped,
                    assetOut: share,
                  },
                  {
                    pool: {
                      Stableswap: share,
                    },
                    assetIn: share,
                    assetOut: "222",
                  },
                ],
              },
            },
          },
          null
        )
      )
    );
  }

  // repayment schedule
  console.log("scheduling hollar repay");
  const hollarAddress = "0x531a654d1696ED52e7275A8cede955E82620f99a";
  const treasuryAddress = await evmAddress(treasury);
  const repayTx = await (
    await getPool()
  ).populateTransaction.repay(
    hollarAddress,
    utils.parseEther("2000"),
    2,
    treasuryAddress
  );
  repayTx.from = treasuryAddress;
  repayTx.gasLimit = 400_000;
  const repayCall = await rootEvmCall(repayTx);
  last.push(hydrationTx.scheduler.scheduleAfter(5, [600, 500], 0, repayCall));

  console.log("scheduling interest repay");
  const repayRest = await (
    await getPool()
  ).populateTransaction.repay(
    hollarAddress,
    MAX_UINT_AMOUNT,
    2,
    treasuryAddress
  );
  repayRest.from = treasuryAddress;
  repayRest.gasLimit = 400_000;
  const repayRestCall = await rootEvmCall(repayRest);
  last.push(
    hydrationTx.scheduler.scheduleAfter(600 * 500 + 300, null, 0, repayRestCall)
  );

  console.log("transfer incentives to the pot");
  const incentiveProxy = "13NWq5jfYPMthrdBpGsj4EaiJi21vDUUMeExcMVEVzzZzuVh";
  const pot = padAddress((await getPotRewardsStrategy())?.address);
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.proxy.proxy(
        incentiveProxy,
        null,
        hydrationTx.currencies.transfer(
          pot,
          69,
          utils.parseEther("11783.39").toString()
        )
      )
    )
  );

  const later = [];
  for (const el of getBatch()) {
    el.from = POOL_ADMIN[hre.network.name];
    later.push(await aaveManagerCall(el));
  }

  txs.push(
    hydrationTx.scheduler.scheduleAfter(
      0,
      null,
      0,
      hydrationTx.utility.batchAll(later)
    )
  );
  txs.push(
    hydrationTx.scheduler.scheduleAfter(
      1,
      null,
      0,
      hydrationTx.utility.batchAll(last)
    )
  );

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
