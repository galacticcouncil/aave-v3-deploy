// @ts-nocheck
import {
  generateProposalV2,
  rootEvmCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import ProposalDecoder from "../../helpers/proposal-decoder";
import chalk from "chalk";
import { exit } from "process";
import {
  FORK,
  POOL_ADMIN,
  getPoolAddressesProvider,
  getACLManager,
} from "../../helpers";

task(`update-reserve-oracle`, ``)
  .addParam("reserve", "symbol of the reserve")
  .setAction(async function (
    { reserve, batch = false }: { reserve: string; batch: boolean },
    hre
  ) {
    const networkId = FORK ? FORK : hre.network.name;
    const admin = POOL_ADMIN[networkId];
    const signer = await hre.ethers.getSigner(admin);
    const poolAddressesProvider = await getPoolAddressesProvider();
    const aclManager = (
      await getACLManager(await poolAddressesProvider.getACLManager())
    ).connect(signer);
    const isPoolAdmin = await aclManager.isPoolAdmin(admin);

    if (!isPoolAdmin) {
      consoleerror(chalk.red(`not pool admin ${admin}`));
      exit(1);
    }

    const txs = [];
    await hre.run("set-reserve-oracle", {
      symbol: reserve,
      batch: true,
    });
    for await (const el of getBatch()) {
      el.from = admin;
      txs.push(await rootEvmCall(el));
    }
    clearBatch();

    let preimage = await generateProposalV2(txs, false);
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    console.log("submit preimages:");
    console.log(preimage.toHex());
    decoder.printTree(decoder.transformCall(preimage.toHuman()));
  });
