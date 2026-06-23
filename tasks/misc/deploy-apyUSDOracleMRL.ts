import { task } from "hardhat/config";

// MDA (multilocation-derived account) of the Ethereum-source XcmTransactor proxy, as seen on Hydration.
// This is the ONLY account allowed to push setPrice() into the oracle via the WHM oracle relay.
// Get it from the whm `oracle-relay-ethereum` migration output: step `003-deploy-transactor` -> `mdaH160`.
// It is DISTINCT from the Solana-source MDA used by deploy-PRIMEoracleMRL, and is SHARED with
// deploy-wstETHOracleMRL (same Ethereum relay -> same transactor -> same MDA). Keep both in sync.
const ETH_SOURCE_MDA: string = "0x54df54a7a32bd5e24d0415cf468b9ff622c626e3"; // whm oracle-relay-ethereum step 003 mdaH160

task(
  `deploy-apyUSDOracleMRL`,
  `Deploys the MRL apyUSD ManagedOracle (owned by the Ethereum-source relay MDA)`
).setAction(async (_, hre) => {
  if (ETH_SOURCE_MDA === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      "ETH_SOURCE_MDA is the zero placeholder — set it to the Ethereum relay XcmTransactor mdaH160 (whm oracle-relay-ethereum step 003) before deploying"
    );
  }

  console.log(`\n- apyUSDOracleMRL deployment`);
  const { deployer } = await hre.getNamedAccounts();

  // Published value = apyUSD.convertToAssets(1e18) (apxUSD per apyUSD share, 18-dec) scaled /1e10 -> 8-dec
  // by the dispatcher. Seeded with the current rate (convertToAssets(1e18)/1e10 ~= 1.3744 apxUSD/apyUSD);
  // the relay overwrites it on the first push.
  const artifact = await hre.deployments.deploy(`apyUSDOracleMRL`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["apyUSD/apxUSD", 1, ETH_SOURCE_MDA, 137441397],
  });

  console.log("apyUSDOracleMRL (ManagedOracle) deployed at:", artifact.address);
  console.log(`\tFinished apyUSDOracleMRL deployment`);
});
