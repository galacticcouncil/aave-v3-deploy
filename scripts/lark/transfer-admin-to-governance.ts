// Transfer GIGAHDX admin roles from our deployer to Hydration's governance
// EVM-mapped account 0xaa7e0000000000000000000000000000000aa7e0 so that proposals
// dispatched via dispatcher.dispatchAsAaveManager satisfy the ACL checks.
//
// Roles/ownerships to move:
//   - ACLManager-GIGAHDX
//     * DEFAULT_ADMIN_ROLE (granted)
//     * POOL_ADMIN (granted)
//     * RISK_ADMIN (granted)
//     * EMERGENCY_ADMIN (granted)
//   - PoolAddressesProvider-GIGAHDX
//     * setACLAdmin(governance)
//     * transferOwnership(governance)
//   - AaveOracle-GIGAHDX is owned by PoolAddressesProvider (no separate ownership)
import hre from "hardhat";

const GOV = "0xaa7e0000000000000000000000000000000aa7e0";

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const deployer = signer.address;
  console.log(`Deployer: ${deployer}`);

  // 1. ACLManager role grants
  const aclArtifact = await hre.deployments.get("ACLManager-GIGAHDX");
  const acl = await hre.ethers.getContractAt(aclArtifact.abi, aclArtifact.address, signer);

  const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";

  const checkAndGrant = async (hasFn: string, grantFn: string, label: string) => {
    const has = await acl[hasFn](GOV);
    if (has) {
      console.log(`  ${label}: already granted to ${GOV}`);
      return;
    }
    console.log(`  Granting ${label} to ${GOV}...`);
    const tx = await acl[grantFn](GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  };

  console.log("=== ACLManager-GIGAHDX roles ===");
  // DEFAULT_ADMIN_ROLE -> grantRole
  const hasDefault = await acl.hasRole(DEFAULT_ADMIN_ROLE, GOV);
  if (!hasDefault) {
    console.log("  Granting DEFAULT_ADMIN_ROLE...");
    const tx = await acl.grantRole(DEFAULT_ADMIN_ROLE, GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  } else {
    console.log("  DEFAULT_ADMIN_ROLE: already set");
  }

  await checkAndGrant("isPoolAdmin", "addPoolAdmin", "POOL_ADMIN");
  await checkAndGrant("isRiskAdmin", "addRiskAdmin", "RISK_ADMIN");
  await checkAndGrant("isEmergencyAdmin", "addEmergencyAdmin", "EMERGENCY_ADMIN");

  // 2. PoolAddressesProvider — set ACL admin + transfer ownership
  console.log("\n=== PoolAddressesProvider-GIGAHDX ===");
  const papArtifact = await hre.deployments.get("PoolAddressesProvider-GIGAHDX");
  const pap = await hre.ethers.getContractAt(papArtifact.abi, papArtifact.address, signer);

  const currentACLAdmin = await pap.getACLAdmin();
  console.log(`  current ACLAdmin: ${currentACLAdmin}`);
  if (currentACLAdmin.toLowerCase() !== GOV.toLowerCase()) {
    console.log(`  setACLAdmin(${GOV})`);
    const tx = await pap.setACLAdmin(GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  }

  const currentOwner = await pap.owner();
  console.log(`  current owner: ${currentOwner}`);
  if (currentOwner.toLowerCase() !== GOV.toLowerCase()) {
    console.log(`  transferOwnership(${GOV})`);
    const tx = await pap.transferOwnership(GOV, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    tx: ${tx.hash}`);
  }

  console.log("\n=== DONE ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
