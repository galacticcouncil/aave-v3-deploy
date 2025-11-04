// @ts-nocheck
import {
  aaveManagerCall,
  getApi,
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

task(`reduce-stables-borrow-rate`, ``).setAction(async function (_, hre) {
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

  await hre.run("review-supply-caps", { fix: true, batch: true });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDC",
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDT",
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDS",
  });

  await hre.run("review-incentive", {
    batch: true,
    reserve: "2-POOL-HUSDE",
  });

  await hre.run("set-oracle-price", {
    oracle: "0x11c1E47AaEcdc47dba8b9B9419b05903e53F3b4f",
    price: "121829858",
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  const { registry } = await getApi();
  const hollarBump = registry.createType(
    "Call",
    "0x28015a01aa7e0000000000000000000000000000000aa7e0531a654d1696ed52e7275a8cede955e82620f99a1101af93df570000000000000000000000008c0f3b9602374198974d2b2679d14a386f5b108e00000000000000000000000000000000000000000004f68ca6d8cd91c60000000000000000000000000000000000000000000000000000000000000000000000400d0300000000000046c32300000000000000000000000000000000000000000000000000000000000000"
  );
  txs.push(hollarBump);

  const proposal = await generateProposalV2(txs, false);

  console.log("proposal hash:", proposal.hash.toHex());
  console.log("proposal batch preimage:");
  console.log(proposal.toHex());

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
});
