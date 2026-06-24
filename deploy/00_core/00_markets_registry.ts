import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { PoolAddressesProviderRegistry } from "../../typechain";
import { waitForTx } from "../../helpers/utilities/tx";
import { COMMON_DEPLOY_PARAMS } from "../../helpers/env";

const func: DeployFunction = async function ({
  getNamedAccounts,
  deployments,
  ...hre
}: HardhatRuntimeEnvironment) {
  const { deploy } = deployments;
  const { deployer, addressesProviderRegistryOwner } = await getNamedAccounts();

  const poolAddressesProviderRegistryArtifact = await deploy(
    "PoolAddressesProviderRegistry",
    {
      from: deployer,
      args: [deployer],
      ...COMMON_DEPLOY_PARAMS,
    }
  );

  const registryInstance = (
    (await hre.ethers.getContractAt(
      poolAddressesProviderRegistryArtifact.abi,
      poolAddressesProviderRegistryArtifact.address
    )) as PoolAddressesProviderRegistry
  ).connect(await hre.ethers.getSigner(deployer));

  // Only transfer ownership if WE currently own the registry (i.e. we just
  // deployed it). When a second market reuses an existing registry already
  // owned by governance, the deployer is not the owner and transferOwnership
  // would revert — registration into that registry is handled via governance.
  const currentOwner = await registryInstance.owner();
  if (currentOwner.toLowerCase() === deployer.toLowerCase()) {
    await waitForTx(
      await registryInstance.transferOwnership(addressesProviderRegistryOwner)
    );
    deployments.log(
      `[Deployment] Transferred ownership of PoolAddressesProviderRegistry to: ${addressesProviderRegistryOwner} `
    );
  } else {
    deployments.log(
      `[Deployment] Reusing existing PoolAddressesProviderRegistry owned by ${currentOwner} — skipping ownership transfer (deployer ${deployer} is not the owner)`
    );
  }
  return true;
};

func.id = "PoolAddressesProviderRegistry";
func.tags = ["core", "registry"];

export default func;
