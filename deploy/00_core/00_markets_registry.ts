import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { PoolAddressesProviderRegistry } from "../../typechain";
import { waitForTx } from "../../helpers/utilities/tx";
import { COMMON_DEPLOY_PARAMS } from "../../helpers/env";
import { EXISTING_PROVIDER_REGISTRY } from "../../helpers/constants";
import { eNetwork } from "../../helpers/types";
import { PoolAddressesProviderRegistry__factory } from "../../typechain";

const func: DeployFunction = async function ({
  getNamedAccounts,
  deployments,
  ...hre
}: HardhatRuntimeEnvironment) {
  const { deploy, save } = deployments;
  const { deployer, addressesProviderRegistryOwner } = await getNamedAccounts();

  // Reuse an existing (shared, governance-owned) registry where configured —
  // e.g. the main Hydration money-market registry on the mainnet-state forks.
  // Adopt its address into this market's deployment artifacts and skip the
  // deploy + ownership transfer. A second market registers its provider into
  // it via governance (see helpers/init-helpers.ts addMarketToRegistry).
  const network = (process.env.FORK || hre.network.name) as eNetwork;
  const existingRegistry = EXISTING_PROVIDER_REGISTRY[network];
  if (existingRegistry) {
    await save("PoolAddressesProviderRegistry", {
      address: existingRegistry,
      abi: PoolAddressesProviderRegistry__factory.abi,
    });
    deployments.log(
      `[Deployment] Reusing existing PoolAddressesProviderRegistry at ${existingRegistry} (shared with main market) `
    );
    return true;
  }

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
