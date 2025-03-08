"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.PERMISSIONED_FAUCET = exports.COMMON_DEPLOY_PARAMS = exports.DETERMINISTIC_DEPLOYMENT = exports.ENABLE_REWARDS = exports.MARKET_NAME = void 0;
const market_config_helpers_1 = require("./market-config-helpers");
exports.MARKET_NAME = process.env.MARKET_NAME || market_config_helpers_1.ConfigNames.Commons;
exports.ENABLE_REWARDS = process.env.ENABLE_REWARDS
    ? process.env.ENABLE_REWARDS === "true"
    : undefined;
exports.DETERMINISTIC_DEPLOYMENT = process.env.DETERMINISTIC_DEPLOYMENT
    ? process.env.DETERMINISTIC_DEPLOYMENT === "true"
    : null;
exports.COMMON_DEPLOY_PARAMS = {
    log: true,
    deterministicDeployment: exports.DETERMINISTIC_DEPLOYMENT ?? false,
};
exports.PERMISSIONED_FAUCET = process.env.PERMISSIONED_FAUCET === "true" || false;
