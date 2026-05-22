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
  `disable-stables-isolation-borrow`,
  `Disable USDC+USDT as borrowable in isolation mode (leaves HOLLAR as the only borrowable asset against PRIME / apyUSD collateral)`
).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const cfg = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const poolConfigurator = await getPoolConfiguratorProxy();

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
  console.log("hash:");
  console.log(proposal.hash.toHex());
});
