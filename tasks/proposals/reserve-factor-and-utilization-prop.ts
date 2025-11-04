// @ts-nocheck
import {
  aaveManagerCall,
  generateProposal,
  generateProposalV2,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`reserve-factor-and-utilization-prop`, ``).setAction(async function (
  _,
  hre
) {
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  const { proposal, whitelistedCall, preimages } = await generateProposalV2(
    txs,
    true
  );

  console.log("proposal hash:", proposal.hash.toHex());
  console.log("proposal batch preimage:");
  console.log(proposal.toHex());

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  decoder.printTree(decoder.transformCall(proposal.toHuman()));

  console.log("preimages:");
  console.log(preimages.toHex());
});
