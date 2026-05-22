// @ts-nocheck
import {
  ConfigNames,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  generateProposalV2,
  getApi,
  location,
  aaveManagerCall,
  dispatchAs,
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

task(`sigil-launch`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const cfg = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;

  console.log("init SIGIL reserve");
  await hre.run("init-reserve", {
    symbol: "SIGIL",
    batch: true,
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  // predict aToken address from deployer nonce
  const deployer = await poolAddressesProvider.getPoolConfigurator();
  const nonce = await hre.ethers.provider.getTransactionCount(deployer);
  const aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });
  console.log("predicted aToken address:", aToken);

  const SIGIL = 816;
  const aSIGIL = 1816;
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  // asset must exist before EVM calls can reference tokenAddress(816)
  const preRegistrationTxs = [
    // register SIGIL token in Hydration asset registry
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: SIGIL,
        name: "Sigil Stable",
        assetType: "Token",
        existentialDeposit: "20000000000000000",
        symbol: "SIGIL",
        decimals: 18,
        location: null,
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    // mint initial Treasury balance (1.1M SIGIL)
    hydrationTx.currencies.updateBalance(
      treasury,
      SIGIL,
      "1100000000000000000000000"
    ),
  ];

  // aToken registration must come after initReserves deploys it
  const postRegistrationTxs = [
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: aSIGIL,
        name: "aSIGIL",
        assetType: "Erc20",
        existentialDeposit: "20000000000000000",
        symbol: "aSIGIL",
        decimals: 18,
        location: location(aToken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    // Treasury swaps entire 1.1M SIGIL for aSIGIL via Aave AMM router
    await dispatchAs(
      treasury,
      hydrationTx.router.sell(
        ...Object.values({
          assetIn: SIGIL,
          assetOut: aSIGIL,
          amount: "1100000000000000000000000",
          minAmountOut: 0,
          route: [{ pool: "Aave", assetIn: SIGIL, assetOut: aSIGIL }],
        })
      )
    ),
  ];

  console.log("generating proposal preimage...");
  const preimage = await generateProposalV2(
    [...preRegistrationTxs, ...txs, ...postRegistrationTxs],
    false
  );

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("proposal preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
