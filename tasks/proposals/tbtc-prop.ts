import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";


import { generateProposal } from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction, getBatch } from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getAToken,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  ZERO_ADDRESS,
} from "../../helpers";
import { network } from "hardhat";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { ReverseContext } from "jsondiffpatch";

task(`tbtc-prop`, ``).setAction(async function (_, hre) {
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolConfigurator = (await getPoolConfiguratorProxy()).connect(signer);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const { utils } = hre.ethers;

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

  console.log("init tbtc reserve");
  await hre.run("init-reserve", {
    symbol: "TBTC",
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


  let deployer;
  try {
    deployer = config.ATokensAndRatesHelper || 
      (await hre.deployments.get("ATokensAndRatesHelper")).address;
  } catch (error) {
    // If not found, use the PoolConfigurator
    deployer = await poolAddressesProvider.getPoolConfigurator();
  }
  console.log("Deployer Address:", deployer);

  const nonce = await hre.ethers.provider.getTransactionCount(deployer);


  const aToken = utils.getContractAddress({
    from: deployer,
    nonce: nonce
  });
  console.log("aToken", aToken);


  const reserveAddress = await getReserveAddress(config, "TBTC");
  console.log("reserveAddress", reserveAddress);

  let tbtcTokenId = 1000765;
  let tokenIdOnHydration = 1006;
  if (aToken) {
    const decimals = 18;
    const token = {
      asset: tokenIdOnHydration,
      symbol: "atBTC",
      address: aToken,
      decimals: decimals,
    };
    console.log("adding", token);
    registerTokens.push(token);
  } else {
    console.log("ATOKEN DOESNT EXIST")
    return Error("AToken should be there at this point")
  }

  const newFeePaymentToken = []; 
  newFeePaymentToken.push({asset: tokenIdOnHydration, price: "10701726019645100"});

  const dispatchSells = []; 

  let treasuryId = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";
  dispatchSells.push({asOrigin: treasuryId, assetIn: 1000765, assetOut: 1006, amount: "5000000000000000000", route: [    
    {
        pool: { AAVE: null }, 
        asset_in: 1000765,    
        asset_out: 1006    
    }
], });

  console.log("proposal batch preimage:");
  let preimages =  (await generateProposal(getBatch(), admin, registerTokens, false, newFeePaymentToken, dispatchSells));

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimages:");
  console.log(preimages.toHex());
  decoder.printTree(decoder.transformCall(preimages.toHuman()));
});

function account(address: any) {
  const prefix = Buffer.from("ETH\0");
  const addressBuffer = Buffer.from(address.replace("0x", ""), "hex");
  const remainingBytes = 32 - prefix.length - addressBuffer.length;
  const padding = Buffer.alloc(remainingBytes);
  return "0x" + Buffer.concat([prefix, addressBuffer, padding]).toString("hex");
}
