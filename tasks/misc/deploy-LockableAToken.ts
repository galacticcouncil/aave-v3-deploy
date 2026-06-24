import { task } from "hardhat/config";
import { POOL_ADMIN } from "../../helpers";
import { getContract, waitForTx } from "../../helpers";

import { POOL_ADDRESSES_PROVIDER_ID } from "../../helpers/deploy-ids";
import { MARKET_NAME } from "../../helpers/env";

import { PoolAddressesProvider } from "../../typechain";

task(
  `deploy-LockableAToken`,
  `Deploys the LockableAToken implementation`
).setAction(async (_, hre) => {
  if (!hre.network.config.chainId) {
    throw new Error("INVALID_CHAIN_ID");
  }
  const { deployer } = await hre.getNamedAccounts();

  const { address: addressesProvider } = await hre.deployments.get(
    POOL_ADDRESSES_PROVIDER_ID
  );

  const addressesProviderInstance = (await getContract(
    "PoolAddressesProvider",
    addressesProvider
  )) as PoolAddressesProvider;

  console.log(`\n- LockableAToken deployment`);

  const pool = await addressesProviderInstance.getPool();
  console.log(`\n- Pool address: ${pool}`);

  const artifact = await hre.deployments.deploy(`LockableAToken-${MARKET_NAME}`, {
    from: deployer,
    contract: "LockableAToken",
    args: [pool],
    gasLimit: 10_000_000,
  });
  console.log("LockableAToken deployed at:", artifact.address);
});
