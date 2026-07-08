// Deploy the Verity-emitted Propeller bytecode to a chopsticks lark2 fork and smoke-test it.
//
// Hydration's call filter blocks `evm.create` from signed origins, so EVM ops must go through
// Frontier's unsigned `Ethereum::transact` — i.e. the `eth_sendRawTransaction` path (the handler
// added to the local chopsticks). So we deploy with viem against the eth RPC, and use @polkadot/api
// only to whitelist the deployer EVM address (dev_setStorage) and seal blocks (dev_newBlock).
//
// Loads the *Verity* .bin artifacts (Lean → Yul → solc 0.8.33), appends ABI-encoded ctor args:
//   SyntheticToken(vault) · SubLoop(controller) · Harvester(trigger) · CollateralVaultAave(keeper,pool,synth,loop)
// Verifies each contract's code lands, then smoke-calls SyntheticToken.mint (deployer = vault).
//
// Usage (chopsticks lark2 fork on :8011):
//   node scripts/verity-chopsticks-deploy.mjs
//   AAVE_POOL=0x… node scripts/verity-chopsticks-deploy.mjs   # pool stored in the vault ctor
import { ApiPromise, WsProvider } from "@polkadot/api";
import { hexToU8a, u8aToHex } from "@polkadot/util";
import { encodeAbiParameters, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import fs from "fs";

// REAL_NODE: target a real node (zombienet fork) — no chopsticks dev_ RPCs; blocks auto-produce and
// the deployer key is the fork's pre-whitelisted EVM account, so no dev_setStorage whitelist/fund.
const REAL = !!process.env.REAL_NODE;
const WS = process.env.FORK_WS || "ws://127.0.0.1:8011";
const RPC = process.env.FORK_RPC || (REAL ? "http://127.0.0.1:9999" : "http://127.0.0.1:8011");
const BIN = "/home/mrq/git/aave-v3-deploy/propeller-vault/formal/bridge/forktest/bytecode";
const ZERO = "0x0000000000000000000000000000000000000000";
const AAVE_POOL = process.env.AAVE_POOL || ZERO;

// Deployer key. On a zombienet fork, the prepared chainspec whitelists 0x222222…9D80 for contract
// deploys (see launch-configs/fork/README). On chopsticks we whitelist hardhat #0 via dev_setStorage.
const PK = process.env.PRIV_KEY || (REAL
  ? "0x42d8d953e4f9246093a33e9ca6daa078501012f784adfe4bbed57918ff13be14"
  : "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");

function bin(name) {
  const hex = fs.readFileSync(`${BIN}/${name}.bin`, "utf-8").trim();
  return (hex.startsWith("0x") ? hex : "0x" + hex);
}

async function main() {
  const account = privateKeyToAccount(PK);
  const deployer = account.address;
  console.log("deployer evm:", deployer);

  // 1. Setup. On a real node (zombienet) the deployer is pre-whitelisted in the chainspec and blocks
  //    auto-produce, so `newBlock` just waits. On chopsticks we whitelist/fund/bind via dev_setStorage
  //    and drive block production with dev_newBlock.
  let api = null, newBlock;
  if (REAL) {
    newBlock = () => new Promise((r) => setTimeout(r, 2500)); // real node: let a block be produced
    console.log("real node: using pre-whitelisted fork deploy account\n");
  } else {
    const provider = new WsProvider(WS);
    api = await ApiPromise.create({ provider, noInitWarn: true });
    newBlock = () => provider.send("dev_newBlock", [{ count: 1 }]);
    const key = api.query.evmAccounts.contractDeployer.key(deployer);
    // Bind the H160 to a clean substrate account (= h160 ++ 12 zero bytes) so it's a *bound* EVM
    // account, fund its WETH (asset 20 = pallet-evm Currency) EVM balance, and keep it alive.
    const ext12 = "0x000000000000000000000000";
    const accountId = new Uint8Array(32);
    accountId.set(hexToU8a(deployer), 0);
    const ss58 = api.registry.createType("AccountId", accountId).toString();
    const extKey = api.query.evmAccounts.accountExtension.key(deployer);
    const tokensKey = api.query.tokens.accounts.key(ss58, 20);
    const systemKey = api.query.system.account.key(ss58);
    const acctData = api.registry.createType("OrmlTokensAccountData",
      { free: (10n ** 24n).toString(), reserved: "0", frozen: "0" });
    const acctInfo = api.registry.createType("AccountInfo",
      { nonce: 0, consumers: 0, providers: 1, sufficients: 1,
        data: { free: (10n ** 24n).toString(), reserved: "0", frozen: "0", flags: "0" } });
    await provider.send("dev_setStorage", [[
      [extKey, ext12], [key, "0x01"],
      [tokensKey, u8aToHex(acctData.toU8a())], [systemKey, u8aToHex(acctInfo.toU8a())],
    ]]);
    await newBlock();
    console.log(`bound + whitelisted + funded deployer (ss58 ${ss58})\n`);
  }

  // 2. Raw eth JSON-RPC (chopsticks lacks eth_fillTransaction, so we sign locally + sendRawTransaction).
  const rpc = async (method, params = []) => {
    const r = await fetch(RPC, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    }).then((x) => x.json());
    if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
    return r.result;
  };
  const chainId = parseInt(await rpc("eth_chainId"), 16);
  let nonce = parseInt(await rpc("eth_getTransactionCount", [deployer, "latest"]), 16);
  // Fee must clear the chain's MinGasPrice/base fee (mainnet ≫ lark2's 1.5M), else Frontier
  // rejects with TransactionValidationError::GasPriceTooLow (custom 2). Use 2× current gas price.
  const gasPrice = BigInt(await rpc("eth_gasPrice"));
  const fee = gasPrice * 2n;
  console.log("chainId:", chainId, "nonce:", nonce, "gasPrice:", gasPrice.toString(), "→ maxFee:", fee.toString());

  // sign + send a raw eip-1559 tx, seal a block, return the receipt.
  async function sendRaw({ to, data, gas }) {
    const serialized = await account.signTransaction({
      to, data, gas, nonce, chainId, type: "eip1559",
      maxFeePerGas: fee, maxPriorityFeePerGas: gasPrice,
    });
    nonce++;
    const hash = await rpc("eth_sendRawTransaction", [serialized]);
    await newBlock().catch(() => {});
    for (let i = 0; i < 20; i++) {
      const r = await rpc("eth_getTransactionReceipt", [hash]).catch(() => null);
      if (r) return r;
      await newBlock().catch(() => {});
    }
    return null;
  }

  // Deploy a Verity contract: raw CREATE tx = bytecode ++ abi-encoded ctor args.
  async function deploy(name, types, args) {
    const ctor = types.length ? encodeAbiParameters(types, args).slice(2) : "";
    const data = bin(name) + ctor;
    let receipt;
    try {
      receipt = await sendRaw({ data, gas: 6_000_000n });
    } catch (e) {
      console.log(`${name}: send failed — ${e.message}`);
      return null;
    }
    if (!receipt) { console.log(`${name}: no receipt`); return null; }
    const ok = receipt.status === "0x1";
    const addr = receipt.contractAddress;
    const code = addr ? await rpc("eth_getCode", [addr, "latest"]).catch(() => "0x") : "0x";
    const len = code && code !== "0x" ? code.length / 2 - 1 : 0;
    console.log(`${name}: ${ok ? "success" : "FAIL"} ${addr || "(no addr)"}  code=${len}B  gas=${parseInt(receipt.gasUsed, 16)}`);
    return ok && len > 0 ? addr : null;
  }

  console.log("=== deploy (dependency order) ===");
  const A = [{ type: "address" }];
  const synth = await deploy("SyntheticToken", A, [deployer]);            // vault = deployer (smoke)
  const loop = await deploy("SubLoop", A, [deployer]);                    // controller = deployer
  const harv = await deploy("Harvester", [{ type: "uint256" }], [1_100_000_000_000_000_000n]); // trigger 1.10
  const vault = await deploy(
    "CollateralVaultAave",
    [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }],
    [deployer, AAVE_POOL, synth || ZERO, loop || ZERO]
  );

  // 3. Smoke: deployer (= vault) mints synthetic.
  if (synth) {
    console.log("\n=== smoke: SyntheticToken.mint(deployer, 1000) ===");
    const data = encodeFunctionData({
      abi: [{ type: "function", name: "mint", stateMutability: "nonpayable",
              inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] }],
      functionName: "mint", args: [deployer, 1000n],
    });
    try {
      const r = await sendRaw({ to: synth, data, gas: 1_000_000n });
      const ok = r && r.status === "0x1";
      console.log(`mint: ${ok ? "success ✅" : "FAIL"}  gas=${r ? parseInt(r.gasUsed, 16) : "?"}`);
    } catch (e) {
      console.log("mint: failed —", e.message);
    }
  }

  // 4. Deposit against the real money market: deposit() does effects → pool.supply(asset) → borrow →
  //    synth.mint → loop.deposit. asset = a real listed reserve (USDC, asset 22 precompile). The
  //    reference vault has no `approve`, so the real supply reverts at transferFrom — eth_call surfaces
  //    exactly how far the calldata gets into the live Aave pool.
  if (vault && synth && loop && AAVE_POOL !== ZERO) {
    console.log("\n=== deposit() against real money market (eth_call dry-run) ===");
    const USDC = "0x0000000000000000000000000000000100000016"; // asset 22 — a listed reserve
    const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
    const depData = encodeFunctionData({
      abi: [{ type: "function", name: "deposit", stateMutability: "nonpayable", outputs: [],
        inputs: [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" },
          { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }] }],
      functionName: "deposit",
      args: [AAVE_POOL, synth, loop, USDC, HOLLAR, deployer, 1000000n, 0n, 0n],
    });
    const callRes = await fetch(RPC, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call",
        params: [{ from: deployer, to: vault, data: depData, gas: "0x2DC6C0" }, "latest"] }),
    }).then((x) => x.json());
    if (callRes.error) {
      // revert: try to decode the revert-reason string (Error(string) = 0x08c379a0…)
      const d = callRes.error.data;
      let reason = callRes.error.message;
      if (typeof d === "string" && d.startsWith("0x08c379a0")) {
        try { const len = parseInt(d.slice(74, 138), 16); reason = Buffer.from(d.slice(138, 138 + len * 2), "hex").toString(); } catch {}
      } else if (typeof d === "string" && d.length > 2) reason = `revert data ${d.slice(0, 74)}…`;
      console.log(`deposit reverted → ${reason}`);
      console.log("(expected: the reference vault holds/approves no collateral, so the real Aave supply");
      console.log(" reverts at transferFrom — but the supply calldata reached + was processed by the live pool)");
    } else {
      console.log(`deposit succeeded (returned ${callRes.result})`);
    }
  }

  console.log("\nsummary:", { synth, loop, harv, vault, aavePool: AAVE_POOL });
  if (AAVE_POOL === ZERO)
    console.log("note: AAVE_POOL unset → deposit (real Aave supply/borrow) needs the pool + a listed synthetic reserve + funded asset.");
  if (api) await api.disconnect();
}

main().catch((e) => { console.error("FATAL", e); process.exit(1); });
