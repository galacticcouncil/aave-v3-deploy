import { task } from "hardhat/config";

// MDA (multilocation-derived account) of the Ethereum-source XcmTransactor proxy, as seen on Hydration.
// This is the ONLY account allowed to push setPrice() into the oracle via the WHM oracle relay.
// Get it from the whm `oracle-relay-ethereum` migration output: step `003-deploy-transactor` -> `mdaH160`.
// It is DISTINCT from the Solana-source MDA used by deploy-PRIMEoracleMRL, and is SHARED with
// deploy-apyUSDOracleMRL (same Ethereum relay -> same transactor -> same MDA). Keep both in sync.
const ETH_SOURCE_MDA = "0x0000000000000000000000000000000000000000"; // TODO: replace with mdaH160

task(
  `deploy-wstETHOracleMRL`,
  `Deploys the MRL wstETH ManagedOracle (owned by the Ethereum-source relay MDA)`
).setAction(async (_, hre) => {
  if (ETH_SOURCE_MDA === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      "ETH_SOURCE_MDA is the zero placeholder — set it to the Ethereum relay XcmTransactor mdaH160 (whm oracle-relay-ethereum step 003) before deploying"
    );
  }

  console.log(`\n- wstETHOracleMRL deployment`);
  const { deployer } = await hre.getNamedAccounts();

  // Published value = wstETH.stEthPerToken() (stETH per wstETH, 18-dec) scaled /1e10 -> 8-dec by the
  // dispatcher. Initial value is a sane placeholder; the relay overwrites it on the first push.
  const artifact = await hre.deployments.deploy(`wstETHOracleMRL`, {
    from: deployer,
    contract: "ManagedOracle",
    args: ["wstETH/ETH", 1, ETH_SOURCE_MDA, 120780546],
  });

  console.log("wstETHOracleMRL (ManagedOracle) deployed at:", artifact.address);
  console.log(`\tFinished wstETHOracleMRL deployment`);
});
