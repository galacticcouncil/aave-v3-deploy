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
//   - EmissionManager + PoolAddressesProviderRegistry (Ownable, deployed fresh
//     for this market) -> transferOwnership(governance)
//
// The deployer KEEPS its ACL roles here so the remaining deploy steps still work
// (grant-risk-admin needs the deployer's DEFAULT_ADMIN); the deployer is stripped
// of every role afterwards by scripts/gigahdx/revoke-deployer.ts (the final
// phase-5 step), leaving governance as the sole admin.
import hre from "hardhat";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { EMERGENCY_ADMIN } from "../../helpers/constants";

const GOV = "0xaa7e0000000000000000000000000000000aa7e0";

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const deployer = signer.address;
  const network = FORK ? FORK : hre.network.name;
  const emergencyAdmin = EMERGENCY_ADMIN[network];
  if (!emergencyAdmin) {
    throw new Error(`EMERGENCY_ADMIN not configured for network '${network}'`);
  }
  console.log(`Deployer: ${deployer}`);
  console.log(`Governance: ${GOV}`);
  console.log(`Emergency admin (${network}): ${emergencyAdmin}`);

  // 1. ACLManager role grants
  const aclArtifact = await hre.deployments.get("ACLManager-GIGAHDX");
  const acl = await hre.ethers.getContractAt(aclArtifact.abi, aclArtifact.address, signer);

  const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";

  const checkAndGrant = async (
    hasFn: string,
    grantFn: string,
    label: string,
    target: string = GOV
  ) => {
    const has = await acl[hasFn](target);
    if (has) {
      console.log(`  ${label}: already granted to ${target}`);
      return;
    }
    console.log(`  Granting ${label} to ${target}...`);
    const tx = await acl[grantFn](target, { gasLimit: 300000 });
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
  // Governance holds emergency admin too (mirrors the main Hydration market).
  await checkAndGrant("isEmergencyAdmin", "addEmergencyAdmin", "EMERGENCY_ADMIN (gov)");
  // Dedicated emergency admin from config (EMERGENCY_ADMIN[network]).
  await checkAndGrant(
    "isEmergencyAdmin",
    "addEmergencyAdmin",
    "EMERGENCY_ADMIN (dedicated)",
    emergencyAdmin
  );

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

  // 3. Ownable contracts deployed fresh for this market — transfer to governance.
  //    (Treasury proxy/controller are reused from Hydration and already gov-owned.)
  console.log("\n=== Ownable handover (EmissionManager, Registry) ===");
  const transferOwnableTo = async (deployId: string, target: string) => {
    let art;
    try {
      art = await hre.deployments.get(deployId);
    } catch {
      console.log(`  ${deployId}: no deployment artifact — skipping`);
      return;
    }
    const c = await hre.ethers.getContractAt(
      [
        "function owner() view returns (address)",
        "function transferOwnership(address) external",
      ],
      art.address,
      signer
    );
    const owner = await c.owner();
    console.log(`  ${deployId} owner: ${owner}`);
    if (owner.toLowerCase() === target.toLowerCase()) {
      console.log(`    already owned by ${target}`);
      return;
    }
    if (owner.toLowerCase() !== deployer.toLowerCase()) {
      console.log(`    not owned by deployer (${owner}) — skipping`);
      return;
    }
    const tx = await c.transferOwnership(target, { gasLimit: 300000 });
    await tx.wait();
    console.log(`    transferOwnership(${target}) tx: ${tx.hash}`);
  };
  await transferOwnableTo("EmissionManager", GOV);
  await transferOwnableTo("PoolAddressesProviderRegistry", GOV);

  console.log("\n=== DONE ===");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
