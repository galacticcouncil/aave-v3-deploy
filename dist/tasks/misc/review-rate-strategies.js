"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const signer_1 = require("../../helpers/utilities/signer");
const market_config_helpers_1 = require("../../helpers/market-config-helpers");
const contract_getters_1 = require("../../helpers/contract-getters");
const config_1 = require("hardhat/config");
const tx_1 = require("../../helpers/utilities/tx");
const env_1 = require("../../helpers/env");
const jsondiffpatch_1 = require("jsondiffpatch");
const chalk_1 = __importDefault(require("chalk"));
const transaction_batch_1 = require("../../helpers/transaction-batch");
// This task will review the InterestRate strategy of each reserve from a Market passed by environment variable MARKET_NAME.
// If the fix flag is present it will change the current strategy of the reserve to the desired strategy from market configuration.
(0, config_1.task)(`review-rate-strategies`, ``)
    // Flag to fix the reserve deploying a new InterestRateStrategy contract with the strategy from market configuration:
    // --fix
    .addFlag("fix")
    .addFlag("deploy")
    // Optional parameter to check only the desired tokens by symbol and separated by comma
    // --only DAI,USDC,ETH
    .addOptionalParam("only")
    .addFlag("batch")
    .setAction(async ({ fix, deploy, only, batch = false, }, hre) => {
    const { deployer, poolAdmin } = await hre.getNamedAccounts();
    const checkOnlyReserves = only ? only.split(",") : [];
    const dataProvider = await (0, contract_getters_1.getAaveProtocolDataProvider)();
    const poolConfigurator = (await (0, contract_getters_1.getPoolConfiguratorProxy)()).connect(await hre.ethers.getSigner(poolAdmin));
    const poolAddressesProvider = await (0, contract_getters_1.getPoolAddressesProvider)();
    const poolConfig = await (0, market_config_helpers_1.loadPoolConfig)(env_1.MARKET_NAME);
    const reserves = await dataProvider.getAllReservesTokens();
    const reservesToCheck = checkOnlyReserves.length
        ? reserves.filter(([reserveSymbol]) => checkOnlyReserves.includes(reserveSymbol))
        : reserves;
    for (let index = 0; index < reservesToCheck.length; index++) {
        const { symbol, tokenAddress } = reservesToCheck[index];
        const normalizedSymbol = symbol.toUpperCase();
        console.log(symbol, normalizedSymbol, tokenAddress);
        if (!normalizedSymbol) {
            console.warn(`- Missing address ${tokenAddress} at ReserveAssets configuration for ${symbol}`);
            continue;
        }
        console.log("- Checking reserve", symbol, `, normalized symbol`, normalizedSymbol);
        const expectedStrategy = poolConfig.ReservesConfig[normalizedSymbol.toUpperCase()].strategy;
        const onChainStrategy = await dataProvider.getInterestRateStrategyAddress(tokenAddress);
        const delta = await compareStrategy(hre, onChainStrategy, expectedStrategy);
        if (delta) {
            console.log(`- Found ${chalk_1.default.red("differences")} at reserve ${normalizedSymbol} versus expected "${expectedStrategy.name}" strategy from configuration`);
            console.log(chalk_1.default.red("Current strategy", "=>", chalk_1.default.green("Desired strategy from config")));
            console.log(jsondiffpatch_1.formatters.console.format(delta, expectedStrategy));
            if (deploy) {
                let newStrategyAddress;
                const strategyName = `ReserveStrategy-${expectedStrategy.name}`;
                const strategy = await hre.deployments.getOrNull(strategyName);
                if (strategy && strategy.address !== onChainStrategy) {
                    console.log("  - Desired strategy already deployed at", strategy.address);
                    const delta = await compareStrategy(hre, strategy.address, expectedStrategy);
                    if (delta) {
                        console.warn("  - Deployed strategy does not match the expected configuration");
                    }
                    else {
                        newStrategyAddress = strategy.address;
                    }
                }
                if (!newStrategyAddress) {
                    console.log(`Deployer: ${deployer}`);
                    console.log(`  - Deploying a new instance of ${strategyName}`);
                    const deployArgs = [
                        poolAddressesProvider.address,
                        expectedStrategy.optimalUsageRatio,
                        expectedStrategy.baseVariableBorrowRate,
                        expectedStrategy.variableRateSlope1,
                        expectedStrategy.variableRateSlope2,
                        expectedStrategy.stableRateSlope1,
                        expectedStrategy.stableRateSlope2,
                        expectedStrategy.baseStableRateOffset,
                        expectedStrategy.stableRateExcessOffset,
                        expectedStrategy.optimalStableToTotalDebtRatio,
                    ];
                    const fixedInterestStrategy = await hre.deployments.deploy(strategyName, {
                        from: deployer,
                        args: deployArgs,
                        contract: "DefaultReserveInterestRateStrategy",
                        log: true,
                    });
                    console.log("  - Deployed new Reserve Interest Strategy of", normalizedSymbol, "at", fixedInterestStrategy.address);
                    newStrategyAddress = fixedInterestStrategy.address;
                }
                if (fix) {
                    console.log("  - Setting new Reserve Interest Strategy address for reserve", normalizedSymbol, " -> ", `${strategyName}(${newStrategyAddress})`);
                    if (batch) {
                        const tx = await poolConfigurator.populateTransaction.setReserveInterestRateStrategyAddress(tokenAddress, newStrategyAddress, { gasLimit: 100000 });
                        (0, transaction_batch_1.addTransaction)(tx);
                    }
                    else {
                        await (0, tx_1.waitForTx)(await poolConfigurator.setReserveInterestRateStrategyAddress(tokenAddress, newStrategyAddress, { gasLimit: 100000 }));
                        console.log("  - Updated Reserve Interest Strategy of", normalizedSymbol, "at", newStrategyAddress);
                    }
                }
            }
        }
        else {
            console.log(chalk_1.default.green(`  - Reserve ${normalizedSymbol} Interest Rate Strategy matches the expected configuration`));
            continue;
        }
    }
});
async function compareStrategy(hre, strategyAddress, expectedStrategy) {
    const onChainStrategy = (await hre.ethers.getContractAt("DefaultReserveInterestRateStrategy", strategyAddress, await (0, signer_1.getFirstSigner)()));
    const currentStrategy = {
        name: expectedStrategy.name,
        optimalUsageRatio: (await onChainStrategy.OPTIMAL_USAGE_RATIO()).toString(),
        baseVariableBorrowRate: await (await onChainStrategy.getBaseVariableBorrowRate()).toString(),
        variableRateSlope1: await (await onChainStrategy.getVariableRateSlope1()).toString(),
        variableRateSlope2: await (await onChainStrategy.getVariableRateSlope2()).toString(),
        stableRateSlope1: await (await onChainStrategy.getStableRateSlope1()).toString(),
        stableRateSlope2: await (await onChainStrategy.getStableRateSlope2()).toString(),
        baseStableRateOffset: await (await onChainStrategy.getBaseStableBorrowRate())
            .sub(await onChainStrategy.getVariableRateSlope1())
            .toString(),
        stableRateExcessOffset: await (await onChainStrategy.getStableRateExcessOffset()).toString(),
        optimalStableToTotalDebtRatio: await (await onChainStrategy.OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO()).toString(),
    };
    return (0, jsondiffpatch_1.diff)(currentStrategy, expectedStrategy);
}
