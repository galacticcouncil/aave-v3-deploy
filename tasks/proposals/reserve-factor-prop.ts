import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`reserve-factor-prop`, ``).setAction(async function (_, hre) {
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

  console.log("review reserve factors");
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  console.log("set liquidation protocol fees for VDOT");
  await hre.run("setup-liquidation-protocol-fee", {
    only: "VDOT",
    batch: true,
  });

  console.log("proposal batch preimage:");
  const proposal = await generateProposal(getBatch(), admin);
  console.log(proposal.toHex());

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
});
