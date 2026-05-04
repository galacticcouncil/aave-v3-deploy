// Manually grant risk admin to ReservesSetupHelper so configureReserves can proceed.
// Needed because configureReservesByHelper gates the addRiskAdmin call on a
// hardcoded POOL_ADMIN address that only matches on mainnet governance.
import hre from "hardhat";

async function main() {
  const aclManager = await hre.deployments.get("ACLManager-GIGAHDX");
  const reservesSetupHelper = await hre.deployments.get("ReservesSetupHelper");

  const [signer] = await hre.ethers.getSigners();
  const acl = await hre.ethers.getContractAt(
    aclManager.abi,
    aclManager.address,
    signer
  );

  const isRiskAdmin = await acl.isRiskAdmin(reservesSetupHelper.address);
  console.log("ReservesSetupHelper isRiskAdmin:", isRiskAdmin);

  if (!isRiskAdmin) {
    const tx = await acl.addRiskAdmin(reservesSetupHelper.address);
    await tx.wait();
    console.log("Added ReservesSetupHelper as risk admin:", tx.hash);
  }

  // Also make sure the ReservesSetupHelper is owned by a signer we can control
  const ReservesSetupHelper = await hre.ethers.getContractAt(
    ["function owner() view returns (address)", "function transferOwnership(address) external"],
    reservesSetupHelper.address,
    signer
  );
  const owner = await ReservesSetupHelper.owner();
  console.log("ReservesSetupHelper owner:", owner);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
