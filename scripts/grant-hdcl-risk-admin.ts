// Manually grant risk admin to ReservesSetupHelper so configureReserves can
// proceed inside the HDCL reserve init proposal. Ported from
// ys-gigahdx/scripts/grant-risk-admin.ts (swapped GIGAHDX→HDCL).
//
// Needed because configureReservesByHelper gates the addRiskAdmin call on a
// hardcoded POOL_ADMIN address that only matches on mainnet governance.
import hre from "hardhat";

async function main() {
  const aclManager = await hre.deployments.get("ACLManager-HDCL");
  const reservesSetupHelper = await hre.deployments.get("ReservesSetupHelper");

  const [signer] = await hre.ethers.getSigners();
  const acl = await hre.ethers.getContractAt(aclManager.abi, aclManager.address, signer);

  const isRiskAdmin = await (acl as any).isRiskAdmin(reservesSetupHelper.address);
  console.log("ReservesSetupHelper isRiskAdmin:", isRiskAdmin);

  if (!isRiskAdmin) {
    const tx = await (acl as any).addRiskAdmin(reservesSetupHelper.address, { gasLimit: 300000 });
    await tx.wait();
    console.log("Added ReservesSetupHelper as risk admin:", tx.hash);
  }

  const ReservesSetupHelper = await hre.ethers.getContractAt(
    ["function owner() view returns (address)", "function transferOwnership(address) external"],
    reservesSetupHelper.address,
    signer
  );
  const owner = await (ReservesSetupHelper as any).owner();
  console.log("ReservesSetupHelper owner:", owner);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
