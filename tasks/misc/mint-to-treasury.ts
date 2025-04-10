import { eNetwork } from "./../../helpers/types";
import { POOL_ADDRESSES_PROVIDER_ID } from "../../helpers/deploy-ids";
import { getAddressFromJson, waitForTx } from "../../helpers/utilities/tx";
import {
  getPool,
  getPoolAddressesProvider,
} from "../../helpers/contract-getters";
import { task } from "hardhat/config";
import { FORK } from "../../helpers/hardhat-config-helpers";
import chalk from "chalk";
import { addTransaction } from "../../helpers/transaction-batch";

task(
  `mint-to-treasury`,
  `Mints unrealized income to treasury for all reserves in the market`
)
  .addFlag("batch", "Add transactions to batch instead of executing directly")
  .setAction(async ({ batch }, hre) => {
    const { poolAdmin } = await hre.getNamedAccounts();
    const network = FORK ? FORK : (hre.network.name as eNetwork);

    // Get necessary contracts
    const poolAddressesProvider = await getPoolAddressesProvider(
      await getAddressFromJson(network, POOL_ADDRESSES_PROVIDER_ID)
    );
    const pool = await getPool(
      await poolAddressesProvider.getPool(),
      await hre.ethers.getSigner(poolAdmin)
    );

    // Get all reserves in the market
    console.log("Retrieving all reserves in the market...");
    const reservesList = await pool.getReservesList();

    console.log(`Found ${reservesList.length} reserves in the market`);

    if (reservesList.length === 0) {
      console.log(chalk.yellow("No reserves found in the market"));
      return;
    }

    // Display reserves that will be minted to treasury
    console.log("Reserves to mint to treasury:");
    for (let i = 0; i < reservesList.length; i++) {
      const reserveAddress = reservesList[i];
      console.log(`- (${reserveAddress})`);
    }

    console.log("Executing mintToTreasury...");

    try {
      const tx = await pool.populateTransaction.mintToTreasury(reservesList, {
        gasLimit: 5000000,
      });

      if (batch) {
        console.log("Adding mintToTreasury transaction to batch");
        addTransaction(tx);
      } else {
        console.log("Executing mintToTreasury transaction...");
        await waitForTx(await pool.signer.sendTransaction(tx));
        console.log(
          chalk.green("Successfully minted to treasury for all reserves")
        );
      }
    } catch (error) {
      console.log(chalk.red("Error executing mintToTreasury:"), error);
    }
  });
