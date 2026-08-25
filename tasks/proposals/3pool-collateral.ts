// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import {
  getBatch,
  clearBatch,
  addTransaction,
} from "../../helpers/transaction-batch";
import {
  ConfigNames,
  getPoolConfiguratorProxy,
  getReserveAddress,
  loadPoolConfig,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { MARKET_NAME } from "../../helpers/env";

task(`3pool-collateral`, ``).setAction(async function (_, hre) {
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolConfigurator = (await getPoolConfiguratorProxy()).connect(signer);
  const txs = [];

  await hre.run("review-reserve-configs", { fix: true, batch: true });

  await hre.run("review-supply-caps", { fix: true, batch: true });

  await hre.run("review-borrow-caps", { fix: true, batch: true });

  {
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(
      await getReserveAddress(config, "3-POOL"),
      config.EModes["StableEMode"].id
    );
    addTransaction(tx);
  }

  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  await hre.run("set-oracle-price", {
    oracle: "0x11c1E47AaEcdc47dba8b9B9419b05903e53F3b4f",
    price: "121095345",
  });

  for (const el of getBatch()) {
    el.from = POOL_ADMIN[hre.network.name];
    txs.push(await aaveManagerCall(el));
  }
  clearBatch();

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
