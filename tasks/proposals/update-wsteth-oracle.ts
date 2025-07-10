// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
  getApi,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import ProposalDecoder from "../../helpers/proposal-decoder";
import chalk from "chalk";
import { exit } from "process";
import {
  FORK,
  POOL_ADMIN,
  getPoolAddressesProvider,
  getACLManager,
} from "../../helpers";

task(`update-wsteth-oracle`).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const signer = await hre.ethers.getSigner(admin);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  const hydrationTx = (await getApi()).tx;

  if (!isPoolAdmin) {
    console.error(chalk.red(`not pool admin ${admin}`));
    exit(1);
  }

  const oracleAddress = "0x11c1E47AaEcdc47dba8b9B9419b05903e53F3b4f";
  const newPrice = "120780546";

  await hre.run("set-oracle-price", {
    oracle: oracleAddress,
    price: newPrice,
  });

  const afterUpgrade = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  afterUpgrade.push(
    hydrationTx.stableswap.updateAssetPegSource(4200, 1000809, {
      MMOracle: oracleAddress,
    })
  );

  const txs = [
    hydrationTx.system.authorizeUpgrade(
      "0xb76d4164995e9d7801bd0cc7d674fc88fb29bb26e32abce2babb6973f74d2423"
    ),
    hydrationTx.scheduler.scheduleAfter(
      900,
      null,
      0,
      hydrationTx.utility.batchAll(afterUpgrade)
    ),
  ];

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
  console.log("hash:");
  console.log(preimage.hash.toHex());
});
