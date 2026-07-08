// Live two-vault shared-SubLoop test against zombienet — the empirical capstone for the
// SubLoopShares ℝ-spec + the SubLoop bridge proofs (conservation + cross-vault isolation).
//
// `SubLoop.deposit`/`requestUnwind` are pure share accounting (no token transfer — the PRIME buy is
// a separate keeper poke), so two distinct msg.senders seeding one loop is all that's needed.
//   vault A = the deployer EOA (calls the loop directly)
//   vault B = a minimal Seeder contract (calls the loop as its own msg.sender)
// After each op we assert on-chain:
//   conservation: totalShares == balanceOf(A) + balanceOf(B)
//   isolation:    the op moved ONLY the acting vault's balanceOf
import { encodeAbiParameters, encodeFunctionData } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import fs from "fs";

const RPC = process.env.FORK_RPC || "http://127.0.0.1:9999";
const LOOPBIN = "/home/mrq/git/aave-propeller-wt/propeller-vault/formal/bridge/forktest/bytecode/SubLoop.bin";
const SEEDERBIN = "/tmp/probe/Seeder.bin";
const PK = "0x42d8d953e4f9246093a33e9ca6daa078501012f784adfe4bbed57918ff13be14";
const account = privateKeyToAccount(PK);
const A = account.address; // vault A = deployer EOA

const rd = (p) => { let h = fs.readFileSync(p, "utf-8").trim(); return h.startsWith("0x") ? h : "0x" + h; };
const rpc = async (m, p = []) => {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: m, params: p }) }).then((x) => x.json());
  if (r.error) throw new Error(`${m}: ${JSON.stringify(r.error)}`);
  return r.result;
};
const ethCall = (to, data) => fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }) })
  .then((x) => x.json());
const chainId = parseInt(await rpc("eth_chainId"), 16);
let nonce = parseInt(await rpc("eth_getTransactionCount", [A, "latest"]), 16);
const gp = BigInt(await rpc("eth_gasPrice")); const fee = gp * 2n;
async function send({ to, data, gas }) {
  const tx = { data, gas, nonce, chainId, type: "eip1559", maxFeePerGas: fee, maxPriorityFeePerGas: gp };
  if (to) tx.to = to;
  const s = await account.signTransaction(tx); nonce++;
  const h = await rpc("eth_sendRawTransaction", [s]);
  for (let i = 0; i < 25; i++) { const r = await rpc("eth_getTransactionReceipt", [h]).catch(() => null); if (r) return r; await new Promise((z) => setTimeout(z, 1500)); }
  return null;
}

// SubLoop reads
const balanceOf = async (loop, who) => BigInt((await ethCall(loop, encodeFunctionData({
  abi: [{ type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }],
  functionName: "balanceOf", args: [who] }))).result);
const totalShares = async (loop) => BigInt((await ethCall(loop, encodeFunctionData({
  abi: [{ type: "function", name: "totalShares", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }],
  functionName: "totalShares", args: [] }))).result);
// SubLoop writes (vault A calls directly)
const depData = (amt) => encodeFunctionData({ abi: [{ type: "function", name: "deposit", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] }], functionName: "deposit", args: [amt] });
const unwData = (amt) => encodeFunctionData({ abi: [{ type: "function", name: "requestUnwind", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] }], functionName: "requestUnwind", args: [amt] });
// Seeder writes (vault B = the seeder contract)
const seederSeed = (loop, amt) => encodeFunctionData({ abi: [{ type: "function", name: "seed", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] }], functionName: "seed", args: [loop, amt] });
const seederUnwind = (loop, amt) => encodeFunctionData({ abi: [{ type: "function", name: "unwind", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] }], functionName: "unwind", args: [loop, amt] });

console.log("=== deploy SubLoop (controller=deployer) + Seeder ===");
const loop = (await send({ data: rd(LOOPBIN) + encodeAbiParameters([{ type: "address" }], [A]).slice(2), gas: 3_000_000n })).contractAddress;
const B = (await send({ data: rd(SEEDERBIN), gas: 2_000_000n })).contractAddress; // vault B
console.log("  SubLoop:", loop, "\n  vault A (EOA):", A, "\n  vault B (Seeder):", B);

let pass = true;
async function check(label, expA, expB, expTot) {
  const [ba, bb, t] = [await balanceOf(loop, A), await balanceOf(loop, B), await totalShares(loop)];
  const cons = t === ba + bb;
  const ok = ba === expA && bb === expB && t === expTot && cons;
  if (!ok) pass = false;
  console.log(`  ${ok ? "✓" : "✗"} ${label}: A=${ba} B=${bb} total=${t}  conservation(total==A+B)=${cons}`);
  return { ba, bb };
}

console.log("\n=== step 1: A deposits 1000 ===");
await send({ to: loop, data: depData(1000n), gas: 400_000n });
const s1 = await check("after A.deposit(1000)", 1000n, 0n, 1000n); // B untouched

console.log("\n=== step 2: B (Seeder) deposits 500 — A must be untouched (isolation) ===");
await send({ to: B, data: seederSeed(loop, 500n), gas: 400_000n });
const s2 = await check("after B.deposit(500)", 1000n, 500n, 1500n);
console.log(`  isolation: A unchanged by B's deposit? ${s1.ba === s2.ba ? "✓" : "✗ A MOVED"}`);

console.log("\n=== step 3: A requestUnwind 400 — B must be untouched (isolation) ===");
await send({ to: loop, data: unwData(400n), gas: 400_000n });
const s3 = await check("after A.requestUnwind(400)", 600n, 500n, 1100n);
console.log(`  isolation: B unchanged by A's unwind? ${s2.bb === s3.bb ? "✓" : "✗ B MOVED"}`);

console.log("\n=== step 4: B requestUnwind 500 — A must be untouched (isolation) ===");
await send({ to: B, data: seederUnwind(loop, 500n), gas: 400_000n });
const s4 = await check("after B.requestUnwind(500)", 600n, 0n, 600n);
console.log(`  isolation: A unchanged by B's unwind? ${s3.ba === s4.ba ? "✓" : "✗ A MOVED"}`);

console.log(pass
  ? "\n✅ TWO-VAULT LIVE TEST PASSED — shared SubLoop conserves shares and isolates vaults on-chain"
  : "\n✗ FAILED");
