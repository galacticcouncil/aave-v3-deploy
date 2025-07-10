import { task } from "hardhat/config";
import chalk from "chalk";
import { addTransaction } from "../../helpers/transaction-batch";

task("set-oracle-price", "Sets the price in a ManagedOracle contract")
  .addParam("oracle", "ManagedOracle contract address")
  .addParam("price", "Price to set (int256)")
  .setAction(async ({ oracle, price }, hre) => {
    const { poolAdmin } = await hre.getNamedAccounts();
    const signer = await hre.ethers.getSigner(poolAdmin);

    console.log(chalk.blue(`Setting price ${price} for oracle ${oracle}...`));

    try {
      const oracleContract = await hre.ethers.getContractAt(
        "ManagedOracle",
        oracle,
        signer
      );

      const tx = await oracleContract.populateTransaction.setPrice(price);

      addTransaction(tx);
      console.log(chalk.green(`✓ Added oracle price update to batch`));
    } catch (error) {
      console.error(chalk.red(`✗ Failed to set price: ${error.message}`));
      throw error;
    }
  });
