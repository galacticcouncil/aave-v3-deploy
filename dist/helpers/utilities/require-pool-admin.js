"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const contract_getters_1 = require("../contract-getters");
const hardhat_config_helpers_1 = require("../hardhat-config-helpers");
const constants_1 = require("../constants");
async function requirePoolAdmin(hre) {
    const { poolAdmin } = await hre.getNamedAccounts();
    const signer = await hre.ethers.getSigner(poolAdmin);
    const poolAddressesProvider = await (0, contract_getters_1.getPoolAddressesProvider)();
    const aclManager = (await (0, contract_getters_1.getACLManager)(await poolAddressesProvider.getACLManager())).connect(signer);
    console.log("poolAdmin", poolAdmin);
    const networkId = hardhat_config_helpers_1.FORK ? hardhat_config_helpers_1.FORK : hre.network.name;
    const admin = constants_1.POOL_ADMIN[networkId];
    const isPoolAdmin = await aclManager.isPoolAdmin(admin);
    if (!isPoolAdmin) {
        throw "not pool admin " + admin;
    }
    return admin;
}
exports.default = requirePoolAdmin;
