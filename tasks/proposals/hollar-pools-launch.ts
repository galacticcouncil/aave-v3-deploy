// @ts-nocheck
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import { getPoolAddressesProvider, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`hollar-pools-launch`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;
  let deployer = await poolAddressesProvider.getPoolConfigurator();
  let nonce = await hre.ethers.provider.getTransactionCount(deployer);

  const txs = [];
  const reserves = [
    "2-POOL-HUSDT",
    "2-POOL-HUSDC",
    "2-POOL-HUSDS",
    "2-POOL-HUSDe",
  ];
  const assetIds = [1009, 1010, 1011, 1012];
  const symbols = ["HUSDT", "HUSDe", "HUSDC", "HUSDS"];
  const displayNames = [
    "Hydrated Tether",
    "Hydrated USDe",
    "Hydrated USDC",
    "Hydrated USDS",
  ];

  // Initialize all reserves
  for (let i = 0; i < reserves.length; i++) {
    console.log(`init ${reserves[i]} reserve`);
    await hre.run("init-reserve", {
      symbol: reserves[i],
      batch: true,
    });
  }

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: false, batch: true });

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: false, batch: true });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: false, batch: true });

  // Process each reserve for incentives
  for (let i = 0; i < reserves.length; i++) {
    let atoken = utils.getContractAddress({
      from: deployer,
      nonce: nonce + 3 * i, // 3x because each reserve deploys atoken, vtoken and stoken
    });

    await hre.run("review-emission-admin", {
      batch: true,
      reserve: reserves[i],
    });

    await hre.run("review-incentive", {
      batch: true,
      reserve: reserves[i],
      incentivize: atoken,
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
      nonce: nonce + i,
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
                Stableswap: 104 + i,
              },
              assetIn: 1002,
              assetOut: 104 + i,
            },
            {
              pool: "Aave",
              assetIn: 104 + i,
              assetOut: assetIds[i],
            },
          ],
        })
      )
    );
  }

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
