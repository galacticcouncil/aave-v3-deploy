// Live round-trip against the real Hydration money market on zombienet:
//   deposit (supply USDC + borrow USDT + mint + loop)  →  pokeSettle (repay USDT + withdraw USDC)
// The empirical counterpart to the ℝ-spec `collateral_out_ge_in`: collateral withdrawn on settle
// ≥ collateral supplied on deposit.
//
// pokeSettle (keeper-only) effects: mainDebt -= repay, totalAssets/Supply -= withdraw; then
//   pool.repay(hollar, repay, 2, onBehalfOf)   — pulls `repay` of the debt asset FROM the vault
//   pool.withdraw(asset, withdraw, recipient)  — burns aToken, sends underlying to recipient
// Both are externalCallWithReturn (real Aave repay/withdraw return uint256) — the return-size guard
// is correct there, unlike the void mint/deposit (see the fix). Pool is an ApprovedContract, so the
// repay's transferFrom from the vault needs no allowance. deposit & pokeSettle land in different
// blocks (Aave bans same-block borrow+repay).
import { encodeAbiParameters, encodeFunctionData, getContractAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import fs from "fs";

const RPC = process.env.FORK_RPC || "http://127.0.0.1:9999";
const BIN = "/home/mrq/git/aave-v3-deploy/propeller-vault/formal/bridge/forktest/bytecode";
const ZERO = "0x0000000000000000000000000000000000000000";
const POOL = process.env.AAVE_POOL || "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const USDC = "0x0000000000000000000000000000000100000016"; // collateral, 6dp
const USDT = "0x000000000000000000000000000000010000000a"; // debt asset, 6dp
const TREASURY = "0x6d6f646c70792f74727372790000000000000000";
const SUPPLY_AMT = 1_000_000n;  // 1 USDC collateral
const FUND_AMT = 2_000_000n;    // fund 2 USDC
const BORROW_AMT = 100_000n;    // 0.1 USDT debt
const SYNTH_AMT = 1_000_000_000_000_000_000n;
const PK = "0x42d8d953e4f9246093a33e9ca6daa078501012f784adfe4bbed57918ff13be14";

const bin = (n) => { const h = fs.readFileSync(`${BIN}/${n}.bin`, "utf-8").trim(); return h.startsWith("0x") ? h : "0x" + h; };
const account = privateKeyToAccount(PK);
const deployer = account.address;
const rpc = async (m, p = []) => {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: m, params: p }) }).then((x) => x.json());
  if (r.error) throw new Error(`${m}: ${JSON.stringify(r.error)}`);
  return r.result;
};
const ethCall = (to, data, from = deployer) => fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ from, to, data, gas: "0x2DC6C0" }, "latest"] }) }).then((x) => x.json());
const decodeRevert = (e) => { const d = e?.data; if (typeof d === "string" && d.startsWith("0x08c379a0")) { try { const l = parseInt(d.slice(74,138),16); return "Error('"+Buffer.from(d.slice(138,138+l*2),"hex").toString()+"')"; } catch {} } return (typeof d === "string" && d.length>2) ? `revert ${d}` : e?.message; };
const chainId = parseInt(await rpc("eth_chainId"), 16);
let nonce = parseInt(await rpc("eth_getTransactionCount", [deployer, "latest"]), 16);
const gp = BigInt(await rpc("eth_gasPrice")); const fee = gp * 2n;
async function send({ to, data, gas }) {
  const tx = { data, gas, nonce, chainId, type: "eip1559", maxFeePerGas: fee, maxPriorityFeePerGas: gp }; if (to) tx.to = to;
  const s = await account.signTransaction(tx); nonce++;
  const h = await rpc("eth_sendRawTransaction", [s]);
  for (let i = 0; i < 25; i++) { const r = await rpc("eth_getTransactionReceipt", [h]).catch(() => null); if (r) return r; await new Promise((z) => setTimeout(z, 1500)); }
  return null;
}
async function deploy(name, types, args) { const ctor = types.length ? encodeAbiParameters(types, args).slice(2) : ""; const r = await send({ data: bin(name) + ctor, gas: 6_000_000n }); const a = r?.contractAddress; const c = a ? await rpc("eth_getCode", [a, "latest"]).catch(() => "0x") : "0x"; console.log(`  ${name}: ${r?.status === "0x1" ? "ok" : "FAIL"} ${a}`); return r?.status === "0x1" && c !== "0x" ? a : null; }
const bal = async (t, w) => { const r = await ethCall(t, encodeFunctionData({ abi: [{ type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }], functionName: "balanceOf", args: [w] })); return r.error ? -1n : BigInt(r.result); };
const A = [{ type: "address" }];

// 1. deploy: keeper = deployer (so it can call pokeSettle); synth minter = predicted vault
const predictedVault = getContractAddress({ from: deployer, nonce: BigInt(nonce + 3) });
console.log("deployer:", deployer, "predicted vault:", predictedVault, "\n=== 1. deploy ===");
const synth = await deploy("SyntheticToken", A, [predictedVault]);
const loop = await deploy("SubLoop", A, [deployer]);
await deploy("Harvester", [{ type: "uint256" }], [1_100_000_000_000_000_000n]);
const vault = await deploy("CollateralVaultAave", [A[0], A[0], A[0], A[0]], [deployer, POOL, synth, loop]);
if (vault?.toLowerCase() !== predictedVault.toLowerCase()) { console.log("vault != predicted"); process.exit(1); }

// 2. fund + deposit
await send({ to: USDC, data: encodeFunctionData({ abi: [{ type: "function", name: "transferFrom", stateMutability: "nonpayable", inputs: [A[0], A[0], { type: "uint256" }], outputs: [{ type: "bool" }] }], functionName: "transferFrom", args: [TREASURY, vault, FUND_AMT] }), gas: 500_000n });
const aUSDC = await (async () => { const r = await ethCall(POOL, "0x35ea6a75" + USDC.slice(2).padStart(64, "0")); const w = r.result.slice(2).match(/.{64}/g) || []; for (const x of w) { const c = "0x" + x.slice(24); if (/^0x[0-9a-f]{40}$/.test(c) && c !== ZERO && !x.slice(0,24).match(/[1-9a-f]/)) { const code = await rpc("eth_getCode", [c, "latest"]).catch(() => "0x"); if (code && code !== "0x") return c; } } return null; })();
console.log("\n=== 2. deposit (supply 1 USDC, borrow 0.1 USDT, onBehalfOf=vault) ===");
const depData = encodeFunctionData({ abi: [{ type: "function", name: "deposit", stateMutability: "nonpayable", outputs: [], inputs: [A[0],A[0],A[0],A[0],A[0],A[0],{type:"uint256"},{type:"uint256"},{type:"uint256"}] }], functionName: "deposit", args: [POOL, synth, loop, USDC, USDT, vault, SUPPLY_AMT, BORROW_AMT, SYNTH_AMT] });
const dr = await send({ to: vault, data: depData, gas: 4_000_000n });
console.log(`  deposit: ${dr?.status === "0x1" ? "SUCCESS" : "FAIL " + dr?.status}`);
console.log(`  vault aUSDC=${await bal(aUSDC, vault)}  vault USDT=${await bal(USDT, vault)}  (borrowed, to repay)`);

// 3. pokeSettle in a later block: repay 0.1 USDT, withdraw 1 USDC to deployer
console.log("\n=== 3. pokeSettle (repay USDT debt + withdraw USDC collateral to deployer) ===");
const depUSDCbefore = await bal(USDC, deployer);
const settleAbi = [{ type: "function", name: "pokeSettle", stateMutability: "nonpayable", outputs: [], inputs: [
  { type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }] }];
//                    pool        hollar(=USDT) asset(=USDC) onBehalfOf  recipient    repay        withdraw
const settleData = encodeFunctionData({ abi: settleAbi, functionName: "pokeSettle", args: [POOL, USDT, USDC, vault, deployer, BORROW_AMT, SUPPLY_AMT] });
const dry = await ethCall(vault, settleData);
console.log("  dry-run:", dry.error ? `reverted (${decodeRevert(dry.error)})` : "ok");
const sr = await send({ to: vault, data: settleData, gas: 4_000_000n });
console.log(`  pokeSettle: ${sr?.status === "0x1" ? "SUCCESS ✅" : "FAIL " + (sr?.status ?? "noreceipt")}  gas=${sr ? parseInt(sr.gasUsed,16) : "?"}`);

console.log("\n=== 4. verify the round-trip ===");
const vAUSDC = await bal(aUSDC, vault), vUSDT = await bal(USDT, vault), depUSDCafter = await bal(USDC, deployer);
const mainDebt = BigInt(await rpc("eth_getStorageAt", [vault, "0x3", "latest"])); // slot 3 = mainDebtSlot
const totAssets = BigInt(await rpc("eth_getStorageAt", [vault, "0x0", "latest"])); // slot 0 = totalAssetsSlot
console.log(`  vault aUSDC:     ${vAUSDC}            (collateral withdrawn → expect ~0)`);
console.log(`  vault USDT:      ${vUSDT}            (debt repaid → expect ~0)`);
console.log(`  vault mainDebt:  ${mainDebt}  totalAssets: ${totAssets}   (accounting wound down)`);
console.log(`  deployer USDC:   ${depUSDCbefore} → ${depUSDCafter}   Δ=+${depUSDCafter - depUSDCbefore}  (collateral returned)`);
if (sr?.status === "0x1" && depUSDCafter - depUSDCbefore >= SUPPLY_AMT)
  console.log(`\n  ✅ ROUND-TRIP CONFIRMED — collateral out (${depUSDCafter - depUSDCbefore}) ≥ collateral in (${SUPPLY_AMT}); live counterpart to collateral_out_ge_in`);
