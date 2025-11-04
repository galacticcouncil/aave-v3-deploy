import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { addTransaction, getBatch } from "../../helpers/transaction-batch";
import { FORK, getPoolAddressesProvider, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(`paxg-prop`, ``).setAction(async function (_, hre) {
  const { poolAdmin } = await hre.getNamedAccounts();
  const poolAddressesProvider = await getPoolAddressesProvider();
  const { utils } = hre.ethers;

  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  console.log("init tbtc reserve");
  await hre.run("init-reserve", {
    symbol: "PAXG",
    batch: true,
  });

  console.log("update rate strategies");
  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
  });

  console.log("review reserve factors");
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  console.log("update reserve configs");
  await hre.run("review-reserve-configs", { fix: true, batch: true });

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  console.log("update borrow caps");
  await hre.run("review-borrow-caps", { fix: true, batch: true });

  console.log("register tokens");
  const registerTokens = [];

  let deployer = await poolAddressesProvider.getPoolConfigurator();
  const nonce = await hre.ethers.provider.getTransactionCount(deployer);
  const aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce,
  });
  console.log("aToken", aToken);

  let apaxg = 1039;
  if (aToken) {
    const decimals = 18;
    const token = {
      asset: apaxg,
      symbol: "aPAGX",
      address: aToken,
      decimals: decimals,
      existentialDeposit: "4675946889957",
    };
    console.log("adding", token);
    registerTokens.push(token);
  } else {
    console.log("ATOKEN DOESNT EXIST");
    return Error("AToken should be there at this point");
  }

  const newFeePaymentToken = [];
  newFeePaymentToken.push({
    asset: apaxg,
    price: "2374169040836",
  });

  let proposals = await generateProposal(
    getBatch(),
    admin,
    registerTokens,
    false,
    newFeePaymentToken
  );

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(proposals.toHex());
  decoder.printTree(decoder.transformCall(proposals.toHuman()));
});
