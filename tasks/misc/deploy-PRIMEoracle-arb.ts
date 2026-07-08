import { task } from "hardhat/config";

// Deploys a fresh PRIME/USD ManagedOracle on lark-2, owned by the propeller
// looper account so the propeller-prime-arb bot can push setPrice() updates
// (mirroring the mainnet PRIMEoracleMRL at 0x82022F…6a07). The AaveOracle PRIME
// source is repointed to this address via a separate Root referendum.
//
//   PRIV_KEY=<funded deployer> npx hardhat deploy-PRIMEoracle-arb --network lark2
//
// owner defaults to the looper key 0xCf235…42E1; initial price defaults to a
// recent mainnet PRIME/USD (8dp) — the bot corrects it on its first cycle.
task(`deploy-PRIMEoracle-arb`, `Deploys the looper-owned PRIME oracle`).setAction(
  async (_, hre) => {
    const owner =
      process.env.ORACLE_OWNER || "0xCf235CCdf55653abdbAA6E734cE41e1A3c6142E1";
    const initialPrice = Number(process.env.PRIME_INIT_PRICE || 104175859);

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`PRIMEoracleArb`, {
      from: deployer,
      contract: "ManagedOracle",
      args: ["PRIME/USD", 1, owner, initialPrice],
    });

    console.log("PRIME arb oracle deployed at:", artifact.address);
    console.log("  owner:", owner, "| initial price (8dp):", initialPrice);
  }
);
