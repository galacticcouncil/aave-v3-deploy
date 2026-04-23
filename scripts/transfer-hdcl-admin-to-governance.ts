// Transfer HDCL admin roles from our deployer to Hydration's governance
// EVM-mapped account 0xaa7e0000000000000000000000000000000aa7e0 so that proposals
// dispatched via dispatcher.dispatchAsAaveManager satisfy the ACL checks.
// Ported from ys-gigahdx/scripts/transfer-admin-to-governance.ts.
//
// Roles/ownerships to move:
//   - ACLManager-HDCL
//     * DEFAULT_ADMIN_ROLE (granted)
//     * POOL_ADMIN (granted)
//     * RISK_ADMIN (granted)
//     * EMERGENCY_ADMIN (granted)
//   - PoolAddressesProvider-HDCL
//     * setACLAdmin(governance)
//     * transferOwnership(governance)
import hre from "hardhat";

const GOV = "0xaa7e0000000000000000000000000000000aa7e0";

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const deployer = signer.address;
  console.log(`Deployer: ${deployer}`);

  const aclArtifact = await hre.deployments.get("ACLManager-HDCL");
  const acl = await hre.ethers.getContractAt(aclArtifact.abi, aclArtifact.address, signer);

  const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";

  const checkAndGrant = async (hasFn: string, grantFn: string, label: string) => {
    const has = await (acl as any)[hasFn](GOV);
    if (has) {
      console.log(`  ${label}: already granted to ${GOV}`);
      return;
    }
    console.log(`  Granting ${label} to ${GOV}...`);
    const tx = await (acl as any)[grantFn](GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  };

  console.log("=== ACLManager-HDCL roles ===");
  const hasDefault = await (acl as any).hasRole(DEFAULT_ADMIN_ROLE, GOV);
  if (!hasDefault) {
    console.log("  Granting DEFAULT_ADMIN_ROLE...");
    const tx = await (acl as any).grantRole(DEFAULT_ADMIN_ROLE, GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  } else {
    console.log("  DEFAULT_ADMIN_ROLE: already set");
  }

  await checkAndGrant("isPoolAdmin", "addPoolAdmin", "POOL_ADMIN");
  await checkAndGrant("isRiskAdmin", "addRiskAdmin", "RISK_ADMIN");
  await checkAndGrant("isEmergencyAdmin", "addEmergencyAdmin", "EMERGENCY_ADMIN");

  console.log("\n=== PoolAddressesProvider-HDCL ===");
  const papArtifact = await hre.deployments.get("PoolAddressesProvider-HDCL");
  const pap = await hre.ethers.getContractAt(papArtifact.abi, papArtifact.address, signer);

  const currentACLAdmin = await (pap as any).getACLAdmin();
  console.log(`  current ACLAdmin: ${currentACLAdmin}`);
  if (currentACLAdmin.toLowerCase() !== GOV.toLowerCase()) {
    console.log(`  setACLAdmin(${GOV})`);
    const tx = await (pap as any).setACLAdmin(GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  }

  const currentOwner = await (pap as any).owner();
  console.log(`  current owner: ${currentOwner}`);
  if (currentOwner.toLowerCase() !== GOV.toLowerCase()) {
    console.log(`  transferOwnership(${GOV})`);
    const tx = await (pap as any).transferOwnership(GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  }

  console.log("\n=== DONE ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
