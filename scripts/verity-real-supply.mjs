// Full REAL leveraged deposit against the live Hydration money market on zombienet.
//
// The reference CollateralVaultAave.deposit bundles four legs against live contracts:
//   pool.supply(USDC) → pool.borrow(DEBT) → synth.mint → loop.deposit
// To make all four commit on the live money market:
//   * supply: the vault needs a USDC balance. The reference vault has no `approve`, but on Hydration
//     the Pool is an EvmAccounts ApprovedContract, so the MultiCurrency precompile's transferFrom
//     SKIPS the allowance check when the Pool is the spender — a balance is enough. We give the vault
//     one the same way: the fork's deploy EOA is ALSO an ApprovedContract, so it transferFroms USDC
//     out of the (H160-addressable) Treasury into the vault, no allowance needed.
//   * borrow: onBehalfOf = the vault itself (msg.sender == onBehalfOf ⇒ no credit delegation). USDC
//     is 80% LTV, debtCeiling 0 (not isolation), so 1 USDC backs a 0.1 DEBT borrow comfortably.
//   * synth.mint: gated to synth.vault, set at construction. The vault address is deterministic
//     (CREATE(deployer, nonce)), so we deploy SyntheticToken with the PREDICTED vault address.
//   * loop.deposit: ungated.
//
//   REAL_NODE=1 node scripts/verity-real-supply.mjs
import { encodeAbiParameters, encodeFunctionData, getContractAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import fs from "fs";

const RPC = process.env.FORK_RPC || "http://127.0.0.1:9999";
const BIN = "/home/mrq/git/aave-v3-deploy/propeller-vault/formal/bridge/forktest/bytecode";
const ZERO = "0x0000000000000000000000000000000000000000";
const POOL = process.env.AAVE_POOL || "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const USDC = "0x0000000000000000000000000000000100000016"; // asset 22, 6dp, LTV 80%
const TREASURY = "0x6d6f646c70792f74727372790000000000000000"; // modl/py/trsry, holds USDC
// debt leg: USDT (asset 10, 6dp, aToken-backed, 80% LTV). The Verity `deposit` borrows whatever
// asset is passed as `hollar`.
// NOTE: the full deposit reverts (empty) NOT at supply/borrow — both commit on the live pool — but
// at the FIRST inter-contract call: the vault's interfaces declare `ISynth.mint`/`ISubLoop.deposit`
// as `returns (Bool)`, while the deployed SyntheticToken.mint / SubLoop.deposit are `Unit` (compile
// to `stop()`, 0-byte return). The vault's external-call-with-return ECM enforces
// `returndatasize >= 32` → `revert(0,0)`. borrow=0 masks it (Aave reverts `26` before mint).
// Fix: declare those interfaces void (matching the impls) — proven by deploying bool-returning
// stubs, which lets the whole supply+borrow+mint+loop deposit commit (aUSDC minted, USDT borrowed).
const DEBT = "0x000000000000000000000000000000010000000a"; // USDT
const SUPPLY_AMT = 1_000_000n;          // 1 USDC collateral
const FUND_AMT = 2_000_000n;            // fund 2 USDC (headroom)
const BORROW_AMT = 100_000n;            // 0.1 USDT (6dp), < 0.8 capacity
const SYNTH_AMT = 1_000_000_000_000_000_000n; // mint 1 synth (LTV-0 floor token)
const PK = "0x42d8d953e4f9246093a33e9ca6daa078501012f784adfe4bbed57918ff13be14";

const bin = (n) => { const h = fs.readFileSync(`${BIN}/${n}.bin`, "utf-8").trim(); return h.startsWith("0x") ? h : "0x" + h; };
const account = privateKeyToAccount(PK);
const deployer = account.address;

const rpc = async (method, params = []) => {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((x) => x.json());
  if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
  return r.result;
};
async function ethCall(to, data, from = deployer) {
  return fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call",
      params: [{ from, to, data, gas: "0x2DC6C0" }, "latest"] }) }).then((x) => x.json());
}
const decodeRevert = (err) => {
  const d = err?.data;
  if (typeof d === "string" && d.startsWith("0x08c379a0")) {
    try { const len = parseInt(d.slice(74, 138), 16); return Buffer.from(d.slice(138, 138 + len * 2), "hex").toString(); } catch {}
  }
  return (typeof d === "string" && d.length > 2) ? `revert ${d}` : err?.message;
};

const chainId = parseInt(await rpc("eth_chainId"), 16);
let nonce = parseInt(await rpc("eth_getTransactionCount", [deployer, "latest"]), 16);
const gasPrice = BigInt(await rpc("eth_gasPrice"));
const fee = gasPrice * 2n;
console.log("deployer:", deployer, "chainId:", chainId, "nonce:", nonce);

async function sendRaw({ to, data, gas }) {
  const serialized = await account.signTransaction({ to, data, gas, nonce, chainId, type: "eip1559",
    maxFeePerGas: fee, maxPriorityFeePerGas: gasPrice });
  nonce++;
  const hash = await rpc("eth_sendRawTransaction", [serialized]);
  for (let i = 0; i < 25; i++) {
    const r = await rpc("eth_getTransactionReceipt", [hash]).catch(() => null);
    if (r) return r;
    await new Promise((res) => setTimeout(res, 1500));
  }
  return null;
}
async function deploy(name, types, args) {
  const ctor = types.length ? encodeAbiParameters(types, args).slice(2) : "";
  const r = await sendRaw({ data: bin(name) + ctor, gas: 6_000_000n });
  const addr = r?.contractAddress;
  const code = addr ? await rpc("eth_getCode", [addr, "latest"]).catch(() => "0x") : "0x";
  const len = code && code !== "0x" ? code.length / 2 - 1 : 0;
  console.log(`  ${name}: ${r?.status === "0x1" ? "ok" : "FAIL"} ${addr} code=${len}B`);
  return r?.status === "0x1" && len > 0 ? addr : null;
}
const bal = async (token, who) => {
  const data = encodeFunctionData({ abi: [{ type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }], functionName: "balanceOf", args: [who] });
  const r = await ethCall(token, data);
  return r.error ? -1n : BigInt(r.result);
};

// vault is the 4th deploy (synth, loop, harv, vault) → nonce+3
const predictedVault = getContractAddress({ from: deployer, nonce: BigInt(nonce + 3) });
console.log("predicted vault:", predictedVault, "\n=== 1. deploy (synth minter = predicted vault) ===");
const A = [{ type: "address" }];
const synth = await deploy("SyntheticToken", A, [predictedVault]); // minter = the vault, not deployer
const loop = await deploy("SubLoop", A, [deployer]);
const harv = await deploy("Harvester", [{ type: "uint256" }], [1_100_000_000_000_000_000n]);
const vault = await deploy("CollateralVaultAave",
  [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }],
  [deployer, POOL, synth, loop]);
if (vault?.toLowerCase() !== predictedVault.toLowerCase()) { console.log("vault != predicted, abort"); process.exit(1); }

console.log("\n=== 2. fund vault with USDC (deployer ApprovedContract → transferFrom, no allowance) ===");
const tf = encodeFunctionData({ abi: [{ type: "function", name: "transferFrom", stateMutability: "nonpayable",
  inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] }],
  functionName: "transferFrom", args: [TREASURY, vault, FUND_AMT] });
const fr = await sendRaw({ to: USDC, data: tf, gas: 500_000n });
console.log(`  transferFrom(treasury→vault): ${fr?.status === "0x1" ? "ok" : "FAIL"}  vault USDC=${(Number(await bal(USDC, vault)) / 1e6).toFixed(6)}`);

// resolve aUSDC + DEBT variable-debt token for verification
console.log("\n=== 3. resolve aUSDC + DEBT debt token ===");
async function reserveTokens(asset) {
  const r = await ethCall(POOL, "0x35ea6a75" + asset.slice(2).padStart(64, "0")); // getReserveData
  if (r.error) return {};
  const w = r.result.slice(2).match(/.{64}/g) || [];
  const out = {};
  for (const word of w) {
    const cand = "0x" + word.slice(24);
    if (/^0x[0-9a-f]{40}$/.test(cand) && cand !== ZERO && !word.slice(0, 24).match(/[1-9a-f]/)) {
      const code = await rpc("eth_getCode", [cand, "latest"]).catch(() => "0x");
      if (code && code !== "0x") (out.aToken ? (out.others ??= []).push(cand) : (out.aToken = cand));
    }
  }
  return out;
}
const ut = await reserveTokens(USDC), ht = await reserveTokens(DEBT);
const aUSDC = ut.aToken; const hollarDebt = ht.others?.[0] || ht.aToken;
console.log("  aUSDC:", aUSDC, " DEBT debt-ish token:", hollarDebt);

console.log("\n=== 4. vault.deposit() → REAL supply + borrow + mint + loop (onBehalfOf = vault) ===");
const aUSDCbefore = aUSDC ? await bal(aUSDC, vault) : -1n;
const depAbi = [{ type: "function", name: "deposit", stateMutability: "nonpayable", outputs: [],
  inputs: [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" },
    { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }] }];
const depData = encodeFunctionData({ abi: depAbi, functionName: "deposit",
  args: [POOL, synth, loop, USDC, DEBT, vault, SUPPLY_AMT, BORROW_AMT, SYNTH_AMT] });
const dry = await ethCall(vault, depData);
// eth_call and a real extrinsic take different execution paths for substrate-backed precompiles
// on Frontier/Hydration, so a dry-run revert can be a false negative — send the real tx regardless.
console.log("  dry-run:", dry.error ? `reverted (${decodeRevert(dry.error)}) — sending real tx anyway` : "ok → sending real tx");
const r = await sendRaw({ to: vault, data: depData, gas: 4_000_000n });
console.log(`  deposit tx: ${r?.status === "0x1" ? "SUCCESS ✅" : "FAIL " + (r?.status ?? "noreceipt")}  gas=${r ? parseInt(r.gasUsed, 16) : "?"}`);

console.log("\n=== 5. verify on-chain state after the committed deposit ===");
const aUSDCafter = aUSDC ? await bal(aUSDC, vault) : -1n;
const synthBal = await bal(synth, vault);
const loopBal = await bal(loop, vault);
const hollarBal = await bal(DEBT, vault);
console.log(`  aUSDC(vault):  ${aUSDCbefore} → ${aUSDCafter}   Δ=${aUSDCafter - aUSDCbefore}  (real supply)`);
console.log(`  DEBT(vault): ${hollarBal}  (borrowed DEBT received)`);
console.log(`  synth(vault):  ${synthBal}  (minted floor token)`);
console.log(`  loop shares:   ${loopBal}  (sub-loop equity seeded)`);
if (aUSDCafter - aUSDCbefore > 0n)
  console.log("\n  ✅ REAL SUPPLY CONFIRMED — the live Hydration money market minted aUSDC to the Verity vault,");
if (hollarBal > 0n) console.log("  ✅ REAL BORROW CONFIRMED — live pool issued DEBT against the supplied collateral.");
