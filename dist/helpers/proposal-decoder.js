"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
// @ts-nocheck
const ethers_1 = require("ethers");
const chalk_1 = __importDefault(require("chalk"));
class ProposalDecoder {
    constructor(hre) {
        this.interfaces = {};
        this.hre = hre;
    }
    async init() {
        const deployments = await this.hre.deployments.all();
        for (const [name, deployment] of Object.entries(deployments)) {
            if (!deployment.abi)
                continue;
            this.interfaces[name] = new ethers_1.ethers.utils.Interface(deployment.abi);
        }
    }
    decodeCall(hexData) {
        if (typeof hexData !== "string" || !hexData.startsWith("0x"))
            return null;
        if (hexData.length < 10)
            return null;
        for (const i of Object.values(this.interfaces)) {
            try {
                const decoded = i.parseTransaction({ data: hexData });
                const params = decoded.args.reduce((acc, arg, i) => {
                    const input = decoded.functionFragment.inputs[i];
                    try {
                        acc[input.name] = this.parseParameter(arg, input);
                    }
                    catch (e) {
                        const start = i * 64 + 8;
                        const end = start + 64;
                        acc[input.name] = "0x" + hexData.slice(start, end);
                    }
                    return acc;
                }, {});
                return { [decoded.name]: params };
            }
            catch (e) {
                continue;
            }
        }
        return hexData;
    }
    parseParameter(arg, type) {
        if (ethers_1.ethers.BigNumber.isBigNumber(arg)) {
            return arg.toString();
        }
        if (Array.isArray(arg)) {
            if (!type.components) {
                return arg.filter((item) => typeof item === "string" && item.startsWith("0x"));
            }
            return arg.map((item) => {
                if (typeof item === "object" && item !== null) {
                    return type.components.reduce((obj, component, j) => {
                        obj[component.name] = this.parseParameter(item[j], component);
                        return obj;
                    }, {});
                }
                return this.parseParameter(item, type.components[0]);
            });
        }
        if (typeof arg === "object" && arg !== null && type.components) {
            return type.components.reduce((obj, component, j) => {
                obj[component.name] = this.parseParameter(arg[j], component);
                return obj;
            }, {});
        }
        return arg;
    }
    transformCall(obj) {
        if (!obj || typeof obj !== "object") {
            if (typeof obj === "string" && obj.startsWith("0x")) {
                const decoded = this.decodeCall(obj);
                return decoded || obj;
            }
            return obj;
        }
        if (Array.isArray(obj)) {
            return obj
                .filter((item) => item != null)
                .map((item) => this.transformCall(item))
                .filter((v) => !(typeof v === "object" &&
                !Array.isArray(v) &&
                !Object.keys(v).length) && !(Array.isArray(v) && !v.length));
        }
        if (obj.section && obj.method) {
            const args = this.transformCall(obj.args);
            if (args != null &&
                (typeof args !== "object" || Object.keys(args).length)) {
                return { [`${obj.section}.${obj.method}`]: args };
            }
            return {};
        }
        return Object.fromEntries(Object.entries(obj)
            .map(([k, v]) => [k, this.transformCall(v)])
            .filter(([_, v]) => v != null &&
            !(typeof v === "object" &&
                !Array.isArray(v) &&
                !Object.keys(v).length) &&
            !(Array.isArray(v) && !v.length)));
    }
    printTree(obj, indent = "", index = -1) {
        if (index >= 0) {
            console.log(`${indent}${chalk_1.default.yellow(`[${index}]`)}`);
            indent += "    ";
        }
        if (typeof obj === "object" && !Array.isArray(obj) && obj !== null) {
            const keys = Object.keys(obj);
            if (keys.every((k) => !isNaN(Number(k)) && keys.length === 42)) {
                const hexString = Object.entries(obj)
                    .sort(([a], [b]) => Number(a) - Number(b))
                    .map(([_, v]) => typeof v === "string" && v.toLowerCase() === "x"
                    ? "0"
                    : v.toString(16).padStart(2, "0").toLowerCase())
                    .join("");
                console.log(`${indent}0x${hexString}`);
                return;
            }
        }
        Object.entries(obj).forEach(([key, value], i, arr) => {
            const isLast = i === arr.length - 1;
            const prefix = indent + (isLast ? "└── " : "├── ");
            const childIndent = indent + (isLast ? "    " : "│   ");
            if (Array.isArray(value) &&
                value.length > 0 &&
                typeof value[0] === "string" &&
                value[0].startsWith("0x")) {
                console.log(`${prefix}${chalk_1.default.yellow(key)}: ${value
                    .map((v) => chalk_1.default.white(v))
                    .join(", ")}`);
                return;
            }
            if (key.includes(".")) {
                console.log(`${prefix}${chalk_1.default.blue.bold(key)}:`);
            }
            else if (Array.isArray(value)) {
                console.log(`${prefix}${chalk_1.default.yellow(key)}:`);
            }
            else if (value && typeof value === "object") {
                if (value.method) {
                    console.log(`${prefix}${chalk_1.default.blue(key)}:`);
                }
                else {
                    console.log(`${prefix}${chalk_1.default.green(key)}:`);
                }
            }
            else if (value === null) {
                console.log(`${prefix}${chalk_1.default.cyan(key)}: ${chalk_1.default.dim("null")}`);
            }
            else if (value && typeof value === "string" && value.startsWith("0x")) {
                const formattedValue = this.colorHex(value);
                console.log(`${prefix}${chalk_1.default.cyan(key)}: ${formattedValue}`);
            }
            else {
                console.log(`${prefix}${chalk_1.default.cyan(key)}: ${chalk_1.default.white(value)}`);
            }
            if (Array.isArray(value) &&
                !(value.length > 0 &&
                    typeof value[0] === "string" &&
                    value[0].startsWith("0x"))) {
                value.forEach((item, idx) => this.printTree(item, childIndent, idx));
            }
            else if (value && typeof value === "object") {
                this.printTree(value, childIndent);
            }
        });
    }
    colorHex(hex) {
        return (chalk_1.default.magenta("0x") +
            hex
                .slice(2)
                .replace(/([1-9a-f][0-9a-f]|0[1-9a-f]|[1-9a-f]0|00)/gi, (match) => {
                return match === "00"
                    ? chalk_1.default.magenta.dim(match)
                    : chalk_1.default.magenta(match);
            }));
    }
}
exports.default = ProposalDecoder;
