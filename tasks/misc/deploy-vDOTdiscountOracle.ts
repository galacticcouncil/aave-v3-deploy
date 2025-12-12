import { task } from "hardhat/config";
import { POOL_ADMIN } from "./../../helpers/constants";
import { ORACLES_AGGREGATOR_ID } from "../../helpers";

task(
  `deploy-vDOT-DiscountOracle`,
  `Deploys the VDOT discount oracle contract`
).setAction(async (_, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }
  const network = hre.network.name;
  const admin = POOL_ADMIN[network];

  console.log(`\n- vDiscountOracle deployment`);
  const { deployer } = await hre.getNamedAccounts();
  const vDiscountOracle = await hre.deployments.deploy(`vDOT-DiscountOracle`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["vDOT discount", 1, admin, 99100000],
  });

  console.log("vDOT DiscountOracle deployed at:", vDiscountOracle.address);

  const artifact = await hre.deployments.deploy(
    `vDOT-Discount-HybridOracleAggregator`,
    {
      from: deployer,
      contract: "HybridOracleAggregator",
      args: [
        vDiscountOracle.address,
        "0x00000100626966726f73746f000000050000000f", // 5,15, LatestBlock, bifrosto
      ],
    }
  );

  console.log("vDOT Discount Oracle aggregator deployed at:", artifact.address);
});
