// @ts-nocheck
import {
  ConfigNames,
  getOracleByAsset,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  getApi,
  location,
  generateProposalV2,
  dispatchAs,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import {
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  FORK,
  getPoolAddressesProvider,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`apyusd`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const cfg = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;

  await hre.run("init-reserve", {
    symbol: "apyUSD",
    batch: true,
  });

  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  await hre.run("review-debt-ceiling", {
    fix: true,
    batch: true,
  });

  const oracle = await getOracleByAsset(cfg, "apyUSD");
  const price = 1.3672318;

  await hre.run("set-oracle-price", {
    oracle,
    price: Math.round(price * 10 ** 8).toString(),
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  const deployer = await poolAddressesProvider.getPoolConfigurator();
  const nonce = await hre.ethers.provider.getTransactionCount(deployer);
  const aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });

  const HOLLAR = 222;
  const APYUSD = 46;
  const aAPYUSD = 1046;
  const poolAPYUSD = 146;
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  // 363,156 apyUSD (held on 16RJh4z1…j4RE multisig, pending transfer to treasury) + 500,000 HOLLAR borrowed by treasury
  const apyUSDSeed = "363156000000000000000000";

  const rootTxs = [
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: aAPYUSD,
        name: "aapyUSD",
        assetType: "Erc20",
        existentialDeposit: "14705882352941200",
        symbol: "aapyUSD",
        decimals: 18,
        location: location(aToken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: aAPYUSD,
        price: "3264705882352940000000",
      })
    ),
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: poolAPYUSD,
        name: "2-Pool-apyUSD",
        assetType: "StableSwap",
        existentialDeposit: "33000000000000000",
        symbol: "2-Pool-apyUSD",
        decimals: 18,
        location: null,
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: poolAPYUSD,
        price: "11190000000000000000000",
      })
    ),
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: poolAPYUSD,
        assets: [APYUSD, HOLLAR],
        amplification: 100,
        fee: 400,
        pegSource: [{ MMOracle: oracle }, { value: [1, 1] }],
        maxPegUpdate: 120,
      })
    ),
    await dispatchAs(
      treasury,
      hydrationTx.stableswap.addAssetsLiquidity(
        ...Object.values({
          poolId: poolAPYUSD,
          assets: [
            { assetId: HOLLAR, amount: "500000000000000000000000" },
            { assetId: APYUSD, amount: apyUSDSeed },
          ],
          minShares: 0,
        })
      )
    ),
  ];

  const { whitelistedCall, proposal } = await generateProposalV2(
    [...txs, ...rootTxs],
    true
  );
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("whitelisted call hash:");
  console.log(whitelistedCall.hash.toString());
  console.log("proposal preimage:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(whitelistedCall.toHuman()));
});
