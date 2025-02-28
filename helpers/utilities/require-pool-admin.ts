import {getACLManager, getPoolAddressesProvider} from "../contract-getters";
import {FORK} from "../hardhat-config-helpers";
import {POOL_ADMIN} from "../constants";

export default async function requirePoolAdmin(hre) {
  const {poolAdmin} = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
      await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  if (!isPoolAdmin) {
    throw "not pool admin " + admin;
  }
  return admin;
}
