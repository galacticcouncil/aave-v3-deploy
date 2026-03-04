// @ts-nocheck
import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  generateProposalV2,
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
  getPoolConfiguratorProxy,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(
  `update-isolation-params`,
  `Enable USDC+USDT as borrowable in isolation and increase PRIME debt ceiling`
).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const cfg = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const poolConfigurator = await getPoolConfiguratorProxy();

  // Enable USDC as borrowable in isolation
  addTransaction(
    await poolConfigurator.populateTransaction.setBorrowableInIsolation(
      await getReserveAddress(cfg, "USDC"),
      true,
      { gasLimit: 100000 }
    )
  );

  // Enable USDT as borrowable in isolation
  addTransaction(
    await poolConfigurator.populateTransaction.setBorrowableInIsolation(
      await getReserveAddress(cfg, "USDT"),
      true,
      { gasLimit: 100000 }
    )
  );

  // Update PRIME debt ceiling from 2,222,222 to 4,000,000
  await hre.run("review-debt-ceiling", {
    fix: true,
    batch: true,
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  const proposal = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("proposal preimage:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
});
