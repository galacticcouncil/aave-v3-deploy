import { task } from "hardhat/config";

task(
  `deploy-clamped-oracle`,
  `Deploys a ClampedOracle wrapping <primary> with <secondary> as the sanity bound`
)
  .addParam("name", "Asset name -- used for the deployment artifact (e.g. PRIME)")
  .addParam("primary", "Primary feed address (push-based: DIA / Chainlink)")
  .addParam(
    "secondary",
    "Secondary feed address (Hydration chainlink TWAP precompile)"
  )
  .addParam("maxDiffBps", "Max allowed deviation from secondary, in bps (0..10000)")
  .setAction(
    async (
      {
        name,
        primary,
        secondary,
        maxDiffBps,
      }: {
        name: string;
        primary: string;
        secondary: string;
        maxDiffBps: string;
      },
      hre
    ) => {
      if (!hre.network.config.chainId) {
        throw new Error("INVALID_CHAIN_ID");
      }

      const bps = parseInt(maxDiffBps, 10);
      if (!Number.isInteger(bps) || bps < 0 || bps > 10_000) {
        throw new Error(`maxDiffBps must be an integer in [0, 10000], got ${maxDiffBps}`);
      }

      const { deployer } = await hre.getNamedAccounts();
      const artifact = await hre.deployments.deploy(`${name}-ClampedOracle`, {
        from: deployer,
        contract: "ClampedOracle",
        args: [primary, secondary, bps],
        log: true,
      });

      console.log(`ClampedOracle(${name}) deployed at: ${artifact.address}`);
      console.log(`  primary:    ${primary}`);
      console.log(`  secondary:  ${secondary}`);
      console.log(`  maxDiffBps: ${bps}`);
    }
  );
