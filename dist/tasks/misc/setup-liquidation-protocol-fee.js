"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const market_config_helpers_1 = require("../../helpers/market-config-helpers");
const config_1 = require("hardhat/config");
const tx_1 = require("../../helpers/utilities/tx");
const market_config_helpers_2 = require("../../helpers/market-config-helpers");
const contract_getters_1 = require("../../helpers/contract-getters");
const ethers_1 = require("ethers");
const env_1 = require("../../helpers/env");
const transaction_batch_1 = require("../../helpers/transaction-batch");
(0, config_1.task)(`setup-liquidation-protocol-fee`, `Setups reserve liquidation protocol fee from configuration`)
    .addFlag("batch")
    .addOptionalParam("only", "only set those assets")
    .setAction(async ({ batch, only }, hre) => {
    const { poolAdmin } = await hre.getNamedAccounts();
    const config = await (0, market_config_helpers_2.loadPoolConfig)(env_1.MARKET_NAME);
    const checkOnlyReserves = only ? only.split(",") : [];
    const poolConfigurator = (await (0, contract_getters_1.getPoolConfiguratorProxy)()).connect(await hre.ethers.getSigner(poolAdmin));
    let assetsWithProtocolFees = [];
    for (let asset in config.ReservesConfig) {
        if (only.length && !checkOnlyReserves.includes(asset))
            continue;
        const liquidationProtocolFee = ethers_1.BigNumber.from(config.ReservesConfig[asset].liquidationProtocolFee);
        const assetAddress = await (0, market_config_helpers_1.getReserveAddress)(config, asset);
        console.log("setting up liquidation protocol fee for", asset, assetAddress);
        if (liquidationProtocolFee && liquidationProtocolFee.gt("0")) {
            const tx = await poolConfigurator.populateTransaction.setLiquidationProtocolFee(assetAddress, liquidationProtocolFee, { gasLimit: 100000 });
            if (batch) {
                (0, transaction_batch_1.addTransaction)(tx);
            }
            else {
                await (0, tx_1.waitForTx)(await poolConfigurator.signer.sendTransaction(tx));
            }
            assetsWithProtocolFees.push(asset);
        }
    }
    if (assetsWithProtocolFees.length) {
        console.log("- Successfully setup liquidation protocol fee:", assetsWithProtocolFees.join(", "));
    }
    else {
        console.log("- None of the assets has the liquidation protocol fee enabled at market configuration");
    }
});
