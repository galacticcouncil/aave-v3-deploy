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

  let preimage = await generateProposalV2(afterUpgrade, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
  console.log("hash:");
  console.log(preimage.hash.toHex());
  let { proposal } = await generateProposalV2(afterUpgrade, true);
  console.log("proposal:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("proposal hash:");
  console.log(proposal.hash.toHex());
});
