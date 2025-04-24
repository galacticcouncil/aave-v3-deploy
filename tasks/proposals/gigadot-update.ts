// @ts-nocheck
import {
  ConfigNames,
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
import { network } from "hardhat";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { exit } from "process";
import { getPotRewardsStrategy } from "../../helpers/contract-getters";
import chalk from "chalk";

task(`gigadot-update`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
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
  const hydrationTx = (await getApi()).tx;
  const threasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  const BNC = 14;
  const HDX = 0;
  const USDT = 10;

  const txs = [];

  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  console.log("review and update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  //NOTE: maybe incentives would have to be delayed because of oracle - test it
  //hm maybe not, pool already exists - oracle should be able to return value
  txs.push(
    await dispatchAs(
      threasury,
      hydrationTx.router.forceInsertRoute(
        ...Object.values({
          assetPair: {
            assetIn:  BNC,
            assetOut: USDT,
          },
          newRoute: [
            { pool: "Omnipool", assetIn: BNC, assetOut: 102 },
            { pool: { Stableswap: 102 }, assetIn: 102, assetOut: USDT },
          ],
        })
      )
    )
  );

  console.log("review and udpate incentives");
  await hre.run("review-emission-admin", { batch: true, reserve: "GDOT" });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(await rootEvmCall(el));
  }
  clearBatch();

  //TODO: remove this delay
  await hre.run("review-incentive", {
    batch: true,
    reserve: "GDOT",
  });
  for await (const el of getBatch()) {
    el.from = admin;
    txs.push(
      hydrationTx.scheduler.scheduleAfter(
        ...Object.values({
          after: 2,
          maybePeriodic: null,
          priority: 0,
          call: await rootEvmCall(el),
        })
      )
    );
  }
  clearBatch();
  
  
  //send rewards to pot
  const rewardsPot = (await getPotRewardsStrategy())?.address;
  if (!rewardsPot || rewardsPot == ZERO_ADDRESS) {
    console.log(rewardsPot);
    console.log(chalk.red(`failed to get rewrds pot address or is not valid`));
    exit(1);
  }
  txs.push(
    hydrationTx.currencies.transfer(
      ...Object.values( {
        dest: padAddress(rewardsPot),
        currencyId: BNC,
        amount: "214,285.000,000,000,000".replaceAll(",", ""). replaceAll(".", "")
      })
    )
  );
  txs.push(
    hydrationTx.currencies.transfer(
      ...Object.values({
        dest: padAddress(rewardsPot),
        currencyId: HDX,
        amount: "2,222,222.000,000,000,000".replaceAll(",", "").replaceAll(".", "")
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
