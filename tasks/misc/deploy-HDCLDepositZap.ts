import { task } from "hardhat/config";

/**
 * Deploys HDCLDepositZap, the atomic single-call helper that bundles
 * HOLLAR deposit + HDCL supply into one EVM transaction.
 *
 * Saves the deployment artifact via hardhat-deploy so the address lands in
 * `deployments/<network>/HDCLDepositZap.json` and downstream tooling (UI
 * config, governance scripts, etc.) can pick it up.
 *
 * Example:
 *   HARDHAT_NETWORK=lark MARKET_NAME=HDCL npx hardhat \
 *     deploy-HDCLDepositZap \
 *     --hollar 0x531a654d1696ED52e7275A8cede955E82620f99a \
 *     --vault  0xB82cF8A62EB1b51a2f2A9d71C120E2fB8ae548D8 \
 *     --pool   0x7d78C0d9c8F6635b2bc481b674bd74E2917392e8 \
 *     --precompile 0x0000000000000000000000000000000100000037
 */
task(
  `deploy-HDCLDepositZap`,
  `Deploys HDCLDepositZap (atomic HOLLAR -> HDCL -> aHDCL helper)`
)
  .addParam("hollar", "HOLLAR token address")
  .addParam("vault", "HDCL vault proxy address")
  .addParam("pool", "HDCL Aave Pool-Proxy address")
  .addParam(
    "precompile",
    "Substrate-asset precompile address for HDCL (e.g. 0x0000…01000000037 for asset id 55)"
  )
  .setAction(
    async (
      {
        hollar,
        vault,
        pool,
        precompile,
      }: {
        hollar: string;
        vault: string;
        pool: string;
        precompile: string;
      },
      hre
    ) => {
      if (!hre.network.config.chainId) {
        throw new Error("INVALID_CHAIN_ID");
      }

      console.log(`\n- HDCLDepositZap deployment`);
      console.log(`  hollar:     ${hollar}`);
      console.log(`  vault:      ${vault}`);
      console.log(`  pool:       ${pool}`);
      console.log(`  precompile: ${precompile}`);

      const { deployer } = await hre.getNamedAccounts();
      const artifact = await hre.deployments.deploy(`HDCLDepositZap`, {
        from: deployer,
        contract: "HDCLDepositZap",
        args: [hollar, vault, pool, precompile],
      });

      console.log("HDCLDepositZap deployed at:", artifact.address);
    }
  );
