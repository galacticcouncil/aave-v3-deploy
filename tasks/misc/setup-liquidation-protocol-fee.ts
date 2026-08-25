import { getReserveAddress } from "../../helpers/market-config-helpers";
import { task } from "hardhat/config";
import { waitForTx } from "../../helpers/utilities/tx";
import {
  ConfigNames,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { getPoolConfiguratorProxy } from "../../helpers/contract-getters";
import { BigNumber } from "ethers";
import { MARKET_NAME } from "../../helpers/env";
import { addTransaction } from "../../helpers/transaction-batch";

task(
  `setup-liquidation-protocol-fee`,
  `Setups reserve liquidation protocol fee from configuration`
)
  .addFlag("batch")
  .addOptionalParam("only", "only set those assets")
  .setAction(async ({ batch, only }, hre) => {
    const { poolAdmin } = await hre.getNamedAccounts();
    const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
    const checkOnlyReserves: string[] = only ? only.split(",") : [];

    const poolConfigurator = (await getPoolConfiguratorProxy()).connect(
      await hre.ethers.getSigner(poolAdmin)
    );

    let assetsWithProtocolFees = [];
    for (let asset in config.ReservesConfig) {
      if (only.length && !checkOnlyReserves.includes(asset)) continue;
      const liquidationProtocolFee = BigNumber.from(
        config.ReservesConfig[asset].liquidationProtocolFee
      );
      const assetAddress = await getReserveAddress(config, asset);

      console.log(
        "setting up liquidation protocol fee for",
        asset,
        assetAddress
      );
      if (liquidationProtocolFee && liquidationProtocolFee.gt("0")) {
        const tx =
          await poolConfigurator.populateTransaction.setLiquidationProtocolFee(
            assetAddress,
            liquidationProtocolFee,
            { gasLimit: 100000 }
          );
        if (batch) {
          addTransaction(tx);
        } else {
          await waitForTx(await poolConfigurator.signer.sendTransaction(tx));
        }
        assetsWithProtocolFees.push(asset);
      }
    }

    if (assetsWithProtocolFees.length) {
      console.log(
        "- Successfully setup liquidation protocol fee:",
        assetsWithProtocolFees.join(", ")
      );
    } else {
      console.log(
        "- None of the assets has the liquidation protocol fee enabled at market configuration"
      );
    }
  });
