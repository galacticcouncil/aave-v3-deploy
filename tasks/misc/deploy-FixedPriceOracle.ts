import { task } from "hardhat/config";
import { MARKET_NAME } from "../../helpers/env";

// Deploys FixedPriceOracle for a named asset on the current network.
// Usage:
//   npx hardhat deploy-FixedPriceOracle \
//     --asset stHDX \
//     --price 2500000 \
//     --network lark1
//
// --price is in 8-decimal format (2500000 = $0.025).

task("deploy-FixedPriceOracle", "Deploys FixedPriceOracle for a test asset")
  .addParam("asset", "symbol used in the deployment name, e.g. stHDX")
  .addParam("price", "initial price with 8 decimals (2500000 = $0.025)")
  .addOptionalParam("owner", "owner address (defaults to deployer)")
  .setAction(async ({ asset, price, owner }, hre) => {
    if (!hre.network.config.chainId) throw new Error("INVALID_CHAIN_ID");

    // Mainnet guard: FixedPriceOracle is a testnet-only mock. The Hydration
    // mainnet stHDX oracle is the EMA-backed USDOracleAdapter at
    // 0x202df3eDac2775b857ee2f61A3569731E53eC713. For prod-fork testing, use
    // HARDHAT_NETWORK=localhost (or hardhat) with FORK=hydration — that points
    // at a local fork node and `network.name` will not be "hydration".
    if (hre.network.name === "hydration") {
      throw new Error(
        "Refusing to deploy FixedPriceOracle on hydration mainnet. " +
          "Use the prod USDOracleAdapter (0x202df3eDac2775b857ee2f61A3569731E53eC713) instead. " +
          "For fork testing, use HARDHAT_NETWORK=localhost FORK=hydration."
      );
    }

    const { deployer } = await hre.getNamedAccounts();
    const ownerAddr = owner || deployer;

    console.log(`\n- FixedPriceOracle deployment`);
    console.log(`  network: ${hre.network.name}`);
    console.log(`  asset:   ${asset}`);
    console.log(`  price:   ${price} (= $${Number(price) / 1e8} at 8-dec)`);
    console.log(`  owner:   ${ownerAddr}`);

    const name = `FixedPriceOracle-${asset}-${MARKET_NAME}`;
    const artifact = await hre.deployments.deploy(name, {
      from: deployer,
      contract: "FixedPriceOracle",
      args: [price, ownerAddr],
      gasLimit: 3_000_000,
    });

    console.log(`\n  ${name} deployed at: ${artifact.address}`);
  });
