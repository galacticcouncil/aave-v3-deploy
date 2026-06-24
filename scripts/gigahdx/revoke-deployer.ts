// Revoke EVERY admin role the deployer still holds on the GIGAHDX ACLManager,
// leaving governance (0xaa7e0…0aa7e0) as the sole admin — so the deployer EOA
// holds nothing once the deploy finishes.
//
// Run as the FINAL deploy step (deploy-all.sh phase 5), AFTER
// transfer-admin-to-governance (which grants governance every role) and
// grant-risk-admin (which still needs the deployer's DEFAULT_ADMIN). The
// deployer removes its named roles while it still has DEFAULT_ADMIN, then
// renounces DEFAULT_ADMIN_ROLE last.
//
// Idempotent: skips any role the deployer no longer holds, so reruns are safe.
// Safety: refuses to run unless governance already holds DEFAULT_ADMIN +
// POOL_ADMIN, so it can never brick the market by removing the last admin.
import hre from "hardhat";

const GOV = "0xaa7e0000000000000000000000000000000aa7e0";
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000";

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const deployer = signer.address;
  console.log(`Deployer: ${deployer}`);

  const aclArtifact = await hre.deployments.get("ACLManager-GIGAHDX");
  const acl = await hre.ethers.getContractAt(
    aclArtifact.abi,
    aclArtifact.address,
    signer
  );

  // Safety: never strip the deployer unless governance is already fully wired in.
  const govDefault = await acl.hasRole(DEFAULT_ADMIN_ROLE, GOV);
  const govPool = await acl.isPoolAdmin(GOV);
  if (!govDefault || !govPool) {
    throw new Error(
      `Refusing to revoke deployer: governance ${GOV} is not fully admin yet ` +
        `(DEFAULT_ADMIN=${govDefault}, POOL_ADMIN=${govPool}). ` +
        `Run transfer-admin-to-governance first.`
    );
  }

  console.log("=== Revoking deployer roles on ACLManager-GIGAHDX ===");

  // Remove the named roles first (deployer still has DEFAULT_ADMIN to do so).
  const removeIfHeld = async (
    hasFn: string,
    removeFn: string,
    label: string
  ) => {
    if (await acl[hasFn](deployer)) {
      console.log(`  ${removeFn}(deployer)...`);
      const tx = await acl[removeFn](deployer, { gasLimit: 300000 });
      await tx.wait();
      console.log(`    tx: ${tx.hash}`);
    } else {
      console.log(`  ${label}: already revoked`);
    }
  };
  await removeIfHeld("isEmergencyAdmin", "removeEmergencyAdmin", "EmergencyAdmin");
  await removeIfHeld("isPoolAdmin", "removePoolAdmin", "PoolAdmin");
  await removeIfHeld("isRiskAdmin", "removeRiskAdmin", "RiskAdmin");

  // Renounce DEFAULT_ADMIN_ROLE last (deployer renounces its own role).
  if (await acl.hasRole(DEFAULT_ADMIN_ROLE, deployer)) {
    console.log("  renounceRole(DEFAULT_ADMIN_ROLE, deployer)...");
    const tx = await acl.renounceRole(DEFAULT_ADMIN_ROLE, deployer, {
      gasLimit: 300000,
    });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  } else {
    console.log("  DEFAULT_ADMIN_ROLE: already revoked");
  }

  // Verify the deployer holds nothing.
  const stillEmerg = await acl.isEmergencyAdmin(deployer);
  const stillPool = await acl.isPoolAdmin(deployer);
  const stillRisk = await acl.isRiskAdmin(deployer);
  const stillDefault = await acl.hasRole(DEFAULT_ADMIN_ROLE, deployer);
  console.log("\n=== Deployer final roles ===");
  console.log(`  DEFAULT_ADMIN  : ${stillDefault}`);
  console.log(`  PoolAdmin      : ${stillPool}`);
  console.log(`  EmergencyAdmin : ${stillEmerg}`);
  console.log(`  RiskAdmin      : ${stillRisk}`);
  if (stillEmerg || stillPool || stillRisk || stillDefault) {
    throw new Error("Deployer still holds roles after revocation — aborting");
  }
  console.log("\nDeployer fully de-admined ✓ — governance is the sole admin.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
