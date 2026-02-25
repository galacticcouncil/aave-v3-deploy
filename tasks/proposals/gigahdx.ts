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
} from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import { FORK, getPoolAddressesProvider, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`gigahdx`, `GIGAHDX governance proposal`).setAction(async function (
  _,
  hre
) {
  const { utils } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  //const cfg = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;

  // Phase A: EVM (Aave) calls

  // 1. Init reserve for STHDX (sets oracle, deploys rate strategy, initializes reserve with LockableAToken, configures risk params)
  await hre.run("init-reserve", {
    symbol: "STHDX",
    batch: true,
  });

  // 2. Review reserve factors
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  // 3. Review debt ceiling
  await hre.run("review-debt-ceiling", {
    fix: true,
    batch: true,
  });

  // Wrap all EVM txs as aaveManagerCall
  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  // Predict aToken address from nonce
  const deployer = await poolAddressesProvider.getPoolConfigurator();
  const nonce = await hre.ethers.provider.getTransactionCount(deployer);
  const aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });

  // Phase B: Substrate root transactions

  const STHDX = 670;
  const GIGAHDX = 67;

  const rootTxs = [
    // Register stHDX (asset 670) — vault share token, underlying for AAVE reserve
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: STHDX,
        name: "stHDX",
        assetType: "Token",
        existentialDeposit: "0", // TODO: needs value
        symbol: "stHDX",
        decimals: 12,
        location: null,
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    /*
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({
          asset: STHDX,
          price: "TODO", // TODO: needs value
        })
      ),
         */
    // Register GIGAHDX (asset 67) as Erc20 pointing to the aToken
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: GIGAHDX,
        name: "GIGAHDX",
        assetType: "Erc20",
        existentialDeposit: "0", // TODO: needs value
        symbol: "GIGAHDX",
        decimals: 12,
        location: location(aToken),
        xcmRateLimit: null,
        isSufficient: true,
      })
    ),
    /*
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({
          asset: GIGAHDX,
          price: "TODO", // TODO: needs value
        })
      ),
         */
  ];

  // Phase C: Generate proposal
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
