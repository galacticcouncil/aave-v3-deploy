import { ethers } from "ethers";
import chalk from "chalk";
import { HardhatRuntimeEnvironment } from "hardhat/types";

export default class ProposalDecoder {
  private interfaces: { [key: string]: ethers.utils.Interface } = {};
  private hre: HardhatRuntimeEnvironment;

  constructor(hre: HardhatRuntimeEnvironment) {
    this.hre = hre;
  }

  async init(): Promise<void> {
    const deployments = await this.hre.deployments.all();

    for (const [name, deployment] of Object.entries(deployments)) {
      if (!deployment.abi) continue;
      this.interfaces[name] = new ethers.utils.Interface(deployment.abi);
    }
  }

  public decodeCall(hexData: string): any {
    if (typeof hexData !== "string" || !hexData.startsWith("0x")) return null;
    if (hexData.length < 10) return null;

    for (const i of Object.values(this.interfaces)) {
      try {
        const decoded = i.parseTransaction({ data: hexData });
        const params = decoded.args.reduce((acc: any, arg: any, i: number) => {
          const input = decoded.functionFragment.inputs[i];
          try {
            acc[input.name] = this.parseParameter(arg, input);
          } catch (e) {
            const start = i * 64 + 8;
            const end = start + 64;
            acc[input.name] = "0x" + hexData.slice(start, end);
          }
          return acc;
        }, {});

        return { [decoded.name]: params };
      } catch (e) {
        continue;
      }
    }

    return hexData;
  }

  private parseParameter(arg: any, type: any): any {
    if (ethers.BigNumber.isBigNumber(arg)) {
      return arg.toString();
    }

    if (Array.isArray(arg)) {
      if (!type.components) {
        return arg.filter(
          (item): item is string =>
            typeof item === "string" && item.startsWith("0x")
        );
      }

      return arg.map((item) => {
        if (typeof item === "object" && item !== null) {
          return type.components.reduce(
            (obj: any, component: any, j: number) => {
              obj[component.name] = this.parseParameter(item[j], component);
              return obj;
            },
            {}
          );
        }
        return this.parseParameter(item, type.components[0]);
      });
    }

    if (typeof arg === "object" && arg !== null && type.components) {
      return type.components.reduce((obj: any, component: any, j: number) => {
        obj[component.name] = this.parseParameter(arg[j], component);
        return obj;
      }, {});
    }

    return arg;
  }

  public transformCall(obj: any): any {
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
        .filter(
          (v) =>
            !(
              typeof v === "object" &&
              !Array.isArray(v) &&
              !Object.keys(v).length
            ) && !(Array.isArray(v) && !v.length)
        );
    }

    if (obj.section && obj.method) {
      const args = this.transformCall(obj.args);
      if (
        args != null &&
        (typeof args !== "object" || Object.keys(args).length)
      ) {
        return { [`${obj.section}.${obj.method}`]: args };
      }
      return {};
    }

    return Object.fromEntries(
      Object.entries(obj)
        .map(([k, v]) => [k, this.transformCall(v)])
        .filter(
          ([_, v]) =>
            v != null &&
            !(
              typeof v === "object" &&
              !Array.isArray(v) &&
              !Object.keys(v).length
            ) &&
            !(Array.isArray(v) && !v.length)
        )
    );
  }

  public printTree(obj: any, indent = "", index = -1): void {
    if (index >= 0) {
      console.log(`${indent}${chalk.yellow(`[${index}]`)}`);
      indent += "    ";
    }

    if (typeof obj === "object" && !Array.isArray(obj) && obj !== null) {
      const keys = Object.keys(obj);
      if (keys.every((k) => !isNaN(Number(k)) && keys.length === 42)) {
        const hexString = Object.entries(obj)
          .sort(([a], [b]) => Number(a) - Number(b))
          .map(([_, v]) =>
            typeof v === "string" && v.toLowerCase() === "x"
              ? "0"
              : v.toString(16).padStart(2, "0").toLowerCase()
          )
          .join("");
        console.log(`${indent}0x${hexString}`);
        return;
      }
    }

    Object.entries(obj).forEach(([key, value], i, arr) => {
      const isLast = i === arr.length - 1;
      const prefix = indent + (isLast ? "└── " : "├── ");
      const childIndent = indent + (isLast ? "    " : "│   ");

      if (
        Array.isArray(value) &&
        value.length > 0 &&
        typeof value[0] === "string" &&
        value[0].startsWith("0x")
      ) {
        console.log(
          `${prefix}${chalk.yellow(key)}: ${value
            .map((v) => chalk.white(v))
            .join(", ")}`
        );
        return;
      }

      if (key.includes(".")) {
        console.log(`${prefix}${chalk.blue.bold(key)}:`);
      } else if (Array.isArray(value)) {
        console.log(`${prefix}${chalk.yellow(key)}:`);
      } else if (value && typeof value === "object") {
        if (value.method) {
          console.log(`${prefix}${chalk.blue(key)}:`);
        } else {
          console.log(`${prefix}${chalk.green(key)}:`);
        }
      } else if (value === null) {
        console.log(`${prefix}${chalk.cyan(key)}: ${chalk.dim("null")}`);
      } else if (value && typeof value === "string" && value.startsWith("0x")) {
        const formattedValue = this.colorHex(value);
        console.log(`${prefix}${chalk.cyan(key)}: ${formattedValue}`);
      } else {
        console.log(`${prefix}${chalk.cyan(key)}: ${chalk.white(value)}`);
      }

      if (
        Array.isArray(value) &&
        !(
          value.length > 0 &&
          typeof value[0] === "string" &&
          value[0].startsWith("0x")
        )
      ) {
        value.forEach((item, idx) => this.printTree(item, childIndent, idx));
      } else if (value && typeof value === "object") {
        this.printTree(value, childIndent);
      }
    });
  }

  private colorHex(hex: string): string {
    return (
      chalk.magenta("0x") +
      hex
        .slice(2)
        .replace(/([1-9a-f][0-9a-f]|0[1-9a-f]|[1-9a-f]0|00)/gi, (match) => {
          return match === "00"
            ? chalk.magenta.dim(match)
            : chalk.magenta(match);
        })
    );
  }
}
