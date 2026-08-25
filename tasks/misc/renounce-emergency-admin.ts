import { EMERGENCY_ADMIN } from "./../../helpers/constants";
import { FORK } from "../../helpers/hardhat-config-helpers";
import { POOL_ADDRESSES_PROVIDER_ID } from "../../helpers/deploy-ids";
import {
  getACLManager,
  getPoolAddressesProvider,
} from "../../helpers/contract-getters";
import { task } from "hardhat/config";
import { getAddressFromJson, waitForTx } from "../../helpers/utilities/tx";
import { exit } from "process";

task(
  `renounce-emergency-admin`,
  `Renounce EmergencyAdmin role as deployer`
).setAction(async (_, hre) => {
  const { deployer } = await hre.getNamedAccounts();

  const deployerSigner = await hre.ethers.getSigner(deployer);

  const networkId = FORK ? FORK : hre.network.name;
  const desiredEmergencyAdmin = EMERGENCY_ADMIN[networkId];
  if (!desiredEmergencyAdmin) {
    console.error(
      "The constant desired emergency admin is undefined. Check missing admin address at MULTISIG_ADDRESS or GOVERNANCE_BRIDGE_EXECUTOR constant"
    );
    exit(403);
  }

  console.log("--- CURRENT DEPLOYER  ---");
  console.table({
    deployer,
  });
  console.log("--- DESIRED EMERGENCY ADMIN ---");
  console.log(desiredEmergencyAdmin);

  const poolAddressesProvider = await getPoolAddressesProvider();

  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(deployerSigner);

  /** Start of Emergency Admin transfer ownership */
  const isDeployerEmergencyAdmin = await aclManager.isEmergencyAdmin(deployer);
  const isMultisigEmergencyAdmin = await aclManager.isEmergencyAdmin(
    desiredEmergencyAdmin
  );

  if (isDeployerEmergencyAdmin && isMultisigEmergencyAdmin) {
    const tx = await waitForTx(
      await aclManager.renounceRole(
        await aclManager.EMERGENCY_ADMIN_ROLE(),
        deployer
      )
    );
    console.log("- Deployer renounced EmergencyAdmin role");
    console.log("- TX:", tx.transactionHash);
  } else if (!isDeployerEmergencyAdmin && isMultisigEmergencyAdmin) {
    console.log(
      "- The deployer already renounced the Emergency Admin role before running this script"
    );
  } else if (isDeployerEmergencyAdmin && !isMultisigEmergencyAdmin) {
    console.log(
      "- The multisig or guardian must be EmergencyAdmin before Deployer resigns"
    );
  }

  /** Output of results*/
  const result = [
    {
      role: "Deployer renounced EmergencyAdmin",
      address: (await aclManager.isEmergencyAdmin(deployer))
        ? "NOT_RENOUNCED"
        : "RENOUNCED",
      assert: !(await aclManager.isEmergencyAdmin(deployer)),
    },
    {
      role: "Owner is still EmergencyAdmin",
      address: (await aclManager.isEmergencyAdmin(desiredEmergencyAdmin))
        ? "YES"
        : "NO",
      assert: await aclManager.isEmergencyAdmin(desiredEmergencyAdmin),
    },
  ];

  console.table(result);

  return;
});
