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
  getACLManager,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`gigadot-update`, ``).setAction(async function (_, hre) {
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolConfigurator = (await getPoolConfiguratorProxy()).connect(signer);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  const gDOTReserveName = "2-POOL-GDOT";

  const txs = [];

  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  console.log("review and update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  console.log("update DOT emode");
  await hre.run("review-e-mode", {
    name: "DotEMode",
    fix: true,
    batch: true,
  });

  console.log("add GDOT to DOT emode");
  {
    const tx = await poolConfigurator.populateTransaction.setAssetEModeCategory(
      await getReserveAddress(config, gDOTReserveName),
      config.EModes["DotEMode"].id
    );
    addTransaction(tx);
  }

  console.log("review and udpate incentives");
  await hre.run("review-emission-admin", {
    batch: true,
    reserve: gDOTReserveName,
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: gDOTReserveName,
  });

  for await (const el of getBatch()) {
    el.from = admin;
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
