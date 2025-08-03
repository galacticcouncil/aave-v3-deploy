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

task(`3pool-collateral`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;
  let deployer = await poolAddressesProvider.getPoolConfigurator();
  let nonce = await hre.ethers.provider.getTransactionCount(deployer);
  let atoken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });
  const txs = [];
  const reserve = "3-POOL";
  const a3pool = 1008;

  console.log("init 3pool reserve");
  await hre.run("init-reserve", {
    symbol: "3-POOL",
    batch: true,
  });

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: false, batch: true });

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: false, batch: true });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: false, batch: true });

  //incentives
  await hre.run("review-emission-admin", {
    batch: true,
    reserve,
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve,
    incentivize: atoken,
  });

  for (const el of getBatch()) {
    el.from = POOL_ADMIN[hre.network.name];
    txs.push(await aaveManagerCall(el));
  }
  clearBatch();

  console.log("transfer incentives");
  txs.push(
    hydrationTx.dispatcher.dispatchAsTreasury(
      hydrationTx.proxy.proxy(
        "13NWq5jfYPMthrdBpGsj4EaiJi21vDUUMeExcMVEVzzZzuVh",
        null,
        hydrationTx.currencies.transfer(
          "7KATdGahab2nbfZL9juM2PzCCvNApWpKKG9K9jpfHBvxz8MA",
          69,
          utils.parseEther("12488.39").toString()
        )
      )
    )
  );

  console.log("register 3-Pool atoken");
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: a3pool,
        name: "a3pool",
        assetType: "Erc20",
        existentialDeposit: utils.parseEther("0.033").toString(),
        symbol: "a3pool",
        decimals: 18,
        location: location(atoken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    )
  );

  //add a3pool as fee payment asset
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: a3pool,
        price: "11,190,000,000,000,000,000,000".replace(/,/g, ""),
      })
    )
  );

  txs.push(
    hydrationTx.router.forceInsertRoute(
      ...Object.values({
        assetPair: {
          assetIn: 0,
          assetOut: a3pool,
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
              Stableswap: 103,
            },
            assetIn: 1002,
            assetOut: 103,
          },
          {
            pool: "Aave",
            assetIn: 103,
            assetOut: a3pool,
          },
        ],
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
