// @ts-nocheck
import {
  ConfigNames,
  getOracleByAsset,
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
import { treasury } from "../../typechain/@aave/periphery-v3/contracts";

task(`prime`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const cfg = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const poolConfigurator = await getPoolConfiguratorProxy();
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;

  // setup isolation
  addTransaction(
    await poolConfigurator.populateTransaction.setBorrowableInIsolation(
      await getReserveAddress(cfg, "USDC"),
      false,
      { gasLimit: 100000 }
    )
  );
  addTransaction(
    await poolConfigurator.populateTransaction.setBorrowableInIsolation(
      await getReserveAddress(cfg, "USDT"),
      false,
      { gasLimit: 100000 }
    )
  );
  addTransaction(
    await poolConfigurator.populateTransaction.setBorrowableInIsolation(
      "0x531a654d1696ed52e7275a8cede955e82620f99a", // HOLLAR
      true,
      { gasLimit: 100000 }
    )
  );

  await hre.run("init-reserve", {
    symbol: "PRIME",
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

  const oracle = await getOracleByAsset(cfg, "PRIME");
  const price = 1.0195357;

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
  const PRIME = 43;
  const aPRIME = 1043;
  const poolPRIME = 143;
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  const rootTxs = [
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: aPRIME,
        name: "aPRIME",
        assetType: "Erc20",
        existentialDeposit: 9901,
        symbol: "aPRIME",
        decimals: 6,
        location: location(aToken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: aPRIME,
        price: "5247524752",
      })
    ),
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: poolPRIME,
        name: "2-Pool-PRIME",
        assetType: "StableSwap",
        existentialDeposit: "33000000000000000",
        symbol: "2-Pool-PRIME",
        decimals: 18,
        location: null,
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: poolPRIME,
        price: "11190000000000000000000",
      })
    ),
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: poolPRIME,
        assets: [PRIME, HOLLAR],
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
          poolId: poolPRIME,
          assets: [
            { assetId: HOLLAR, amount: "500000000000000000000000" },
            {
              assetId: PRIME,
              amount: Math.round((500_000 / price) * 10 ** 6),
            },
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
