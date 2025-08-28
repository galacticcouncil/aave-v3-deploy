// @ts-nocheck
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import { getPoolAddressesProvider, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`hollar-pools-update`, ``).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const poolAddressesProvider = await getPoolAddressesProvider();
  const hydrationTx = (await getApi()).tx;

  const txs = [];
  const reserves = [
    "2-POOL-HUSDC",
    "2-POOL-HUSDT",
    "2-POOL-HUSDS",
    "2-POOL-HUSDE",
  ];

  console.log("update supply caps");
  await hre.run("review-supply-caps", {
    fix: true,
    batch: true,
  });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", {
    fix: true,
    batch: true,
  });

  for (let i = 0; i < reserves.length; i++) {
    // console.log("update reserve configs");
    // await hre.run("review-reserve-configs", {
    //   fix: true,
    //   batch: true,
    //   only: reserves[i],
    // });

    await hre.run("review-emission-admin", {
      batch: true,
      reserve: reserves[i],
    });

    // await hre.run("review-incentive", {
    //   batch: true,
    //   reserve: reserves[i],
    // });
  }

  for (const el of getBatch()) {
    el.from = POOL_ADMIN[hre.network.name];
    txs.push(await aaveManagerCall(el));
  }

  let preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});
