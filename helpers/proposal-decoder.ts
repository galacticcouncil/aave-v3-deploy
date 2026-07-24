// @ts-nocheck
import { ethers } from "ethers";
import chalk from "chalk";
import fs from "fs";
import path from "path";
import { decodeAddress } from "@polkadot/util-crypto";
import { HardhatRuntimeEnvironment } from "hardhat/types";

export default class ProposalDecoder {
  private interfaces: { [key: string]: ethers.utils.Interface } = {};
  private addressNames: { [key: string]: string } = {};
  private hre: HardhatRuntimeEnvironment;

  constructor(hre: HardhatRuntimeEnvironment) {
    this.hre = hre;
  }

  async init(): Promise<void> {
    // Load artifacts from every deployments/<network> namespace, not just the
    // active one. A proposal routinely mixes contracts across markets (e.g. the
    // BIL namespace plus the main money-market in `hydration`), so resolving
    // addresses / decoding calldata needs ABIs from all of them. The active
    // network is loaded last so its names win on address collisions.
    const deploymentsRoot = this.hre.config.paths.deployments || "deployments";
    const activeNetwork = this.hre.network.name;

    let namespaces: string[] = [];
    try {
      namespaces = fs
        .readdirSync(deploymentsRoot, { withFileTypes: true })
        .filter((d) => d.isDirectory())
        .map((d) => d.name);
    } catch {
      // deployments dir missing — fall back to the active network only below.
    }

    // Active network last so it overrides any name conflicts.
    const ordered = [
      ...namespaces.filter((n) => n !== activeNetwork),
      ...(namespaces.includes(activeNetwork) ? [activeNetwork] : []),
    ];

    for (const namespace of ordered) {
      const dir = path.join(deploymentsRoot, namespace);
      this.loadNamespace(dir);
      // `_addresses.json` is hardhat-deploy's flat name->address export. It
      // holds many entries that never get a standalone artifact JSON (e.g.
      // GhoOracle), so mine it for name resolution (no ABI available).
      this.loadAddressMap(path.join(dir, "_addresses.json"));
    }

    // Curated map of addresses that are neither hardhat-deploy artifacts nor
    // generically derivable: governance origins + runtime-minted money-market
    // proxies (aTokens / GHO facilitator tokens). Loaded last so a hand label
    // wins over anything else. Lives under helpers/ (deployments/ is gitignored
    // apart from whitelisted network folders). See helpers/well-known-addresses.json.
    this.loadAddressMap(
      path.join(this.hre.config.paths.root, "helpers", "well-known-addresses.json")
    );

    // If the filesystem scan found nothing (unusual paths / in-memory), keep
    // the original behaviour so we never regress to zero artifacts.
    if (!Object.keys(this.interfaces).length) {
      const deployments = await this.hre.deployments.all();
      for (const [name, deployment] of Object.entries(deployments)) {
        this.registerArtifact(name, deployment);
      }
    }
  }

  /**
   * Register every `name -> 0xaddress` pair found in a JSON file. The map may
   * be nested (values that are objects are walked recursively); keys starting
   * with `_` are treated as comments and skipped. Provides name resolution
   * only — these sources carry no ABI.
   */
  private loadAddressMap(filePath: string): void {
    let parsed: any;
    try {
      parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
    } catch {
      return;
    }

    const walk = (node: any, name: string): void => {
      if (typeof node === "string") {
        if (/^0x[0-9a-fA-F]{40}$/.test(node)) {
          this.addressNames[node.toLowerCase()] = name;
        }
        return;
      }
      if (node && typeof node === "object") {
        for (const [k, v] of Object.entries(node)) {
          if (k.startsWith("_")) continue;
          // Prefer the leaf key as the label, but keep the parent key when the
          // leaf is a generic field like "address".
          const label = /^address$/i.test(k) ? name : k;
          walk(v, label);
        }
      }
    };

    walk(parsed, "");
  }

  private loadNamespace(dir: string): void {
    let files: string[] = [];
    try {
      files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
    } catch {
      return;
    }

    for (const file of files) {
      // Skip hardhat-deploy bookkeeping files (e.g. _addresses.json).
      if (file.startsWith("_")) continue;
      const name = file.replace(/\.json$/, "");
      try {
        const deployment = JSON.parse(
          fs.readFileSync(path.join(dir, file), "utf8")
        );
        this.registerArtifact(name, deployment);
      } catch {
        continue;
      }
    }
  }

  private registerArtifact(name: string, deployment: any): void {
    if (!deployment || typeof deployment !== "object") return;
    if (deployment.address) {
      this.addressNames[deployment.address.toLowerCase()] = name;
    }
    if (!deployment.abi) return;
    try {
      this.interfaces[name] = new ethers.utils.Interface(deployment.abi);
    } catch {
      // Malformed ABI — skip, don't abort the whole load.
    }
  }

  /** Substrate asset ids seen in this project, mapped to their symbols. */
  private static readonly ASSET_SYMBOLS: { [id: number]: string } = {
    0: "HDX",
    1: "H2O",
    20: "WETH",
    55: "BIL",
    222: "HOLLAR",
    550: "uBIL",
    10055: "2-Pool-BIL",
  };

  /** Well-known substrate PalletId ("modl<8 ascii>") → readable name. */
  private static readonly PALLET_NAMES: { [id: string]: string } = {
    "py/trsry": "Treasury",
  };

  public resolveAddress(address: string): string | null {
    if (typeof address !== "string" || !address.startsWith("0x") || address.length !== 42) return null;
    const lower = address.toLowerCase();

    // Structural addresses (asset precompiles, pallet accounts) are resolved
    // first: their derived label is always the truest name, so it should win
    // over any incidental name a deploy export happened to attach to them.

    // Hydration asset precompiles: 16-byte prefix 0x…01 followed by the u32
    // asset id in the low 4 bytes (e.g. 0x…0100000226 == asset 550). Label
    // with the known symbol, else the raw id.
    const precompile = lower.match(/^0x0{31}1([0-9a-f]{8})$/);
    if (precompile) {
      const assetId = parseInt(precompile[1], 16);
      const symbol = ProposalDecoder.ASSET_SYMBOLS[assetId];
      return symbol ? `${symbol} (asset ${assetId})` : `asset ${assetId}`;
    }

    // Substrate pallet accounts as H160: ASCII "modl" + 8-byte PalletId +
    // padding (e.g. 0x6d6f646c70792f7472737279… == "modlpy/trsry" = Treasury).
    if (lower.startsWith("0x6d6f646c")) {
      const palletId = Buffer.from(lower.slice(10, 26), "hex").toString(
        "latin1"
      );
      return ProposalDecoder.PALLET_NAMES[palletId] || `pallet:${palletId}`;
    }

    return this.addressNames[lower] || null;
  }

  /**
   * Resolve a substrate SS58 address to a readable name. Currently identifies
   * pallet accounts — AccountId32s of the form ASCII "modl" + 8-byte PalletId
   * + zero padding (e.g. the Treasury, shown in the decoded tree as a
   * `system.Signed` origin). Returns null for anything that isn't a pallet
   * account (ordinary user accounts are left as their SS58 string).
   *
   * Gated by a base58 + length pre-check so it never tries to decode the many
   * non-address strings in a proposal tree (numbers, symbols, percentages).
   */
  public resolveSubstrate(value: string): string | null {
    if (typeof value !== "string") return null;
    // 32-byte AccountId32 SS58 strings are 47-48 base58 chars.
    if (!/^[1-9A-HJ-NP-Za-km-z]{47,48}$/.test(value)) return null;

    let pubkey: Uint8Array;
    try {
      pubkey = decodeAddress(value);
    } catch {
      return null;
    }
    if (pubkey.length !== 32) return null;

    const hex = Buffer.from(pubkey).toString("hex");
    // "modl" prefix == 0x6d6f646c.
    if (!hex.startsWith("6d6f646c")) return null;
    const palletId = Buffer.from(hex.slice(8, 24), "hex").toString("latin1");
    return ProposalDecoder.PALLET_NAMES[palletId] || `pallet:${palletId}`;
  }

  /** Best readable label for a scalar value (EVM address or SS58), or null. */
  private labelFor(value: any): string | null {
    if (typeof value !== "string") return null;
    if (value.startsWith("0x")) return this.resolveAddress(value);
    return this.resolveSubstrate(value);
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

    // Primitive leaf reached directly (e.g. a scalar array element like an
    // asset id "55" or a peg value "1"). Print it as-is. Without this guard
    // the `Object.entries(obj)` walk below iterates a string's characters,
    // rendering "55" as `0: 5 / 1: 5` and "222" as `0: 2 / 1: 2 / 2: 2`.
    if (obj === null || typeof obj !== "object") {
      if (typeof obj === "string" && obj.startsWith("0x")) {
        const name = this.resolveAddress(obj);
        const formatted = this.colorHex(obj);
        console.log(
          `${indent}${
            name ? `${formatted} ${chalk.bold.yellow(`(${name})`)}` : formatted
          }`
        );
      } else {
        const name = this.labelFor(obj);
        console.log(
          `${indent}${chalk.white(obj)}${
            name ? ` ${chalk.bold.yellow(`(${name})`)}` : ""
          }`
        );
      }
      return;
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
            .map((v) => {
              const name = this.resolveAddress(v);
              return name ? `${chalk.white(v)} ${chalk.bold.yellow(`(${name})`)}` : chalk.white(v);
            })
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
        const name = this.resolveAddress(value);
        const formattedValue = this.colorHex(value);
        if (name) {
          console.log(`${prefix}${chalk.cyan(key)}: ${formattedValue} ${chalk.bold.yellow(`(${name})`)}`);
        } else {
          console.log(`${prefix}${chalk.cyan(key)}: ${formattedValue}`);
        }
      } else {
        // Non-hex scalar (number, symbol, or an SS58 account like a
        // `system.Signed` origin). Append a name if it resolves — this is how
        // the Treasury pallet account gets labeled in the tree.
        const name = this.labelFor(value);
        console.log(
          `${prefix}${chalk.cyan(key)}: ${chalk.white(value)}${
            name ? ` ${chalk.bold.yellow(`(${name})`)}` : ""
          }`
        );
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
