// Post-deploy script for the BIL Vault. Mirrors bil-vault/DEPLOYMENT.md
// Steps 2 (role grants) + 3 (seed deposit), with optional admin/upgrader
// role transfer to a governance address.
//
// Idempotent: each step probes current state before touching anything,
// skipping no-ops. Safe to re-run after a partial landing.
//
// Runnable against either:
//   - chopsticks fork (default RPC=http://localhost:8000, chain 222222)
//   - mainnet            (set RPC=https://rpc.hydradx.cloud)
//
// Usage:
//   VAULT_ADDRESS=0x...          \         # proxy address from deploy step
//   PRIVATE_KEY=0x...            \         # deployer (= ADMIN_ROLE holder)
//   GUARDIAN_ADDRESS=0x...       \         # optional: granted GUARDIAN_ROLE
//   KEEPER_ADDRESS=0x...         \         # optional: granted CLAIM_OPERATOR_ROLE
//   SEED_AMOUNT=100              \         # optional: HOLLAR to seed (whole units)
//   NEW_ADMIN=0x...              \         # optional: rotate roles to this (governance)
//   RPC=http://localhost:8000              # default: chopsticks
//   node scripts/post-deploy-vault.mjs
//
// Env var notes:
//   - VAULT_ADDRESS + PRIVATE_KEY are REQUIRED. Everything else is optional;
//     omit to skip the corresponding step.
//   - The deployer must hold ADMIN_ROLE on the vault (Deploy.s.sol grants
//     this to the address provided at construction time).
//   - To run against mainnet, set RPC + use legacy txs (script does this
//     automatically via type:"legacy" + dynamic gasPrice query).
//   - For seed: deployer must have SEED_AMOUNT HOLLAR (18 decimals) in
//     their EVM-side balance. On chopsticks, prefund via `dev_setStorage`
//     on Tokens.Accounts[<mapped>, 222]. On mainnet, source it however.

import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toBytes,
  parseAbi,
  parseUnits,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ── env ────────────────────────────────────────────────────────────────
const RPC = process.env.RPC ?? "http://localhost:8000";
const PK = process.env.PRIVATE_KEY;
const VAULT = process.env.VAULT_ADDRESS;
const GUARDIAN = process.env.GUARDIAN_ADDRESS;
const KEEPER = process.env.KEEPER_ADDRESS;
const SEED_AMOUNT = process.env.SEED_AMOUNT;
const NEW_ADMIN = process.env.NEW_ADMIN;
const HOLLAR = process.env.HOLLAR_ADDRESS ?? "0x531a654d1696ED52e7275A8cede955E82620f99a";

if (!PK || !VAULT) {
  console.error("PRIVATE_KEY and VAULT_ADDRESS are required");
  process.exit(2);
}

const chain = {
  id: 222222,
  name: "hydration",
  nativeCurrency: { name: "WETH", symbol: "WETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
};
const account = privateKeyToAccount(PK);
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ chain, account, transport: http(RPC) });

// Hydration is legacy-only EVM. Fetch the live floor at runtime
// (DynamicEvmFee, ≈3.78M wei mainnet, 1.5M lark) and add 10% headroom.
const networkGasPrice = await pub.getGasPrice();
const GAS_PRICE = (networkGasPrice * 110n) / 100n;
const txOpts = { type: "legacy", gas: 1_500_000n, gasPrice: GAS_PRICE };

// ── role hashes (must match BILVault.sol:63-78) ──────────────────────
const DEFAULT_ADMIN_ROLE = "0x" + "00".repeat(32);
const ADMIN_ROLE = keccak256(toBytes("ADMIN_ROLE"));
const UPGRADER_ROLE = keccak256(toBytes("UPGRADER_ROLE"));
const GUARDIAN_ROLE = keccak256(toBytes("GUARDIAN_ROLE"));
const CLAIM_OPERATOR_ROLE = keccak256(toBytes("CLAIM_OPERATOR_ROLE"));

const VAULT_ABI = parseAbi([
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function grantRole(bytes32 role, address account)",
  "function renounceRole(bytes32 role, address account)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function exchangeRate() view returns (uint256)",
  "function getPositionCount() view returns (uint256)",
  "function getOraclePrice() view returns (uint256)",
]);
const HOLLAR_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
]);

const log = (label, val) => console.log(`  ${label.padEnd(28)} ${val}`);

console.log(`network gasPrice: ${networkGasPrice}  using: ${GAS_PRICE}`);
console.log(`vault: ${VAULT}`);
console.log(`deployer: ${account.address}\n`);

// ── sanity: deployer must hold ADMIN_ROLE ─────────────────────────────
console.log("=== sanity check ===");
const deployerIsAdmin = await pub.readContract({
  address: VAULT,
  abi: VAULT_ABI,
  functionName: "hasRole",
  args: [ADMIN_ROLE, account.address],
});
log("deployer has ADMIN_ROLE:", deployerIsAdmin);
if (!deployerIsAdmin) {
  console.error("\n❌ deployer doesn't hold ADMIN_ROLE — cannot post-deploy");
  process.exit(1);
}

// ── helpers ───────────────────────────────────────────────────────────
const grant = async (role, who, label) => {
  const already = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "hasRole",
    args: [role, who],
  });
  if (already) {
    log(`${label}:`, `already on ${who} — skip`);
    return;
  }
  const h = await wallet.writeContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "grantRole",
    args: [role, who],
    ...txOpts,
  });
  const r = await pub.waitForTransactionReceipt({ hash: h, timeout: 60_000 });
  log(`${label}:`, `granted to ${who} (tx ${h.slice(0, 16)}…, gas ${r.gasUsed})`);
};

const renounce = async (role, label) => {
  const has = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "hasRole",
    args: [role, account.address],
  });
  if (!has) {
    log(`renounce ${label}:`, "deployer doesn't hold it — skip");
    return;
  }
  const h = await wallet.writeContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "renounceRole",
    args: [role, account.address],
    ...txOpts,
  });
  const r = await pub.waitForTransactionReceipt({ hash: h, timeout: 60_000 });
  log(`renounce ${label}:`, `tx ${h.slice(0, 16)}…, gas ${r.gasUsed}`);
};

// ── Step 2a: grant GUARDIAN_ROLE ──────────────────────────────────────
if (GUARDIAN) {
  console.log("\n=== Step 2a: grant GUARDIAN_ROLE ===");
  await grant(GUARDIAN_ROLE, GUARDIAN, "GUARDIAN_ROLE");
} else {
  console.log("\n[skip Step 2a] no GUARDIAN_ADDRESS set");
}

// ── Step 2b: grant CLAIM_OPERATOR_ROLE ────────────────────────────────
if (KEEPER) {
  console.log("\n=== Step 2b: grant CLAIM_OPERATOR_ROLE ===");
  await grant(CLAIM_OPERATOR_ROLE, KEEPER, "CLAIM_OPERATOR_ROLE");
} else {
  console.log("\n[skip Step 2b] no KEEPER_ADDRESS set");
}

// ── Step 3: seed deposit ──────────────────────────────────────────────
if (SEED_AMOUNT && Number(SEED_AMOUNT) > 0) {
  console.log("\n=== Step 3: seed deposit ===");
  const seedAtoms = parseUnits(SEED_AMOUNT, 18);
  const positionsBefore = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "getPositionCount",
  });
  log("positions before:", positionsBefore);

  if (positionsBefore > 0n) {
    log("seed:", "already done (≥1 position) — skip");
  } else {
    const hollarBal = await pub.readContract({
      address: HOLLAR,
      abi: HOLLAR_ABI,
      functionName: "balanceOf",
      args: [account.address],
    });
    log("deployer HOLLAR balance:", hollarBal);
    if (hollarBal < seedAtoms) {
      console.error(`\n❌ insufficient HOLLAR: have ${hollarBal}, need ${seedAtoms}`);
      console.error("   (On chopsticks: fund via dev_setStorage on Tokens.Accounts[<mapped>, 222])");
      process.exit(1);
    }

    // Approve HOLLAR → vault (only if current allowance is insufficient)
    const currentAllowance = await pub.readContract({
      address: HOLLAR,
      abi: HOLLAR_ABI,
      functionName: "allowance",
      args: [account.address, VAULT],
    });
    if (currentAllowance < seedAtoms) {
      const ah = await wallet.writeContract({
        address: HOLLAR,
        abi: HOLLAR_ABI,
        functionName: "approve",
        args: [VAULT, seedAtoms],
        ...txOpts,
      });
      const ar = await pub.waitForTransactionReceipt({ hash: ah, timeout: 60_000 });
      log("HOLLAR.approve:", `tx ${ah.slice(0, 16)}…, gas ${ar.gasUsed}`);
    } else {
      log("HOLLAR.approve:", "already sufficient — skip");
    }

    // Deposit
    const dh = await wallet.writeContract({
      address: VAULT,
      abi: VAULT_ABI,
      functionName: "deposit",
      args: [seedAtoms, account.address],
      ...txOpts,
      gas: 5_000_000n, // deposit creates a Decentral position; bump headroom
    });
    const dr = await pub.waitForTransactionReceipt({ hash: dh, timeout: 60_000 });
    log("vault.deposit:", `tx ${dh.slice(0, 16)}…, gas ${dr.gasUsed}, status ${dr.status}`);
    if (dr.status !== "success") {
      console.error("\n❌ deposit reverted");
      process.exit(1);
    }
  }

  // Verify invariants
  console.log("\n  — invariants after seed —");
  const totalAssets = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "totalAssets",
  });
  const totalSupply = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "totalSupply",
  });
  const exchangeRate = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "exchangeRate",
  });
  const positions = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "getPositionCount",
  });
  log("totalAssets:", totalAssets);
  log("totalSupply:", totalSupply);
  log("exchangeRate:", `${exchangeRate} (=$${Number(exchangeRate) / 1e18})`);
  log("positions:", positions);
  // Per DEPLOYMENT.md Step 3 invariants
  const erDelta = exchangeRate > 10n ** 18n ? exchangeRate - 10n ** 18n : 10n ** 18n - exchangeRate;
  if (totalSupply === 0n) console.warn("  ⚠️  totalSupply == 0");
  if (totalAssets === 0n) console.warn("  ⚠️  totalAssets == 0");
  if (erDelta > 10n) console.warn(`  ⚠️  exchangeRate drifted >10 wei from 1e18 (Δ=${erDelta})`);
  if (positions === 0n) console.warn("  ⚠️  no positions created — Decentral pool may be paused");
} else {
  console.log("\n[skip Step 3] no SEED_AMOUNT set");
}

// ── Optional: rotate admin/upgrader roles to governance ───────────────
if (NEW_ADMIN) {
  console.log("\n=== Optional: rotate admin/upgrader to governance ===");
  console.log(`  target: ${NEW_ADMIN}`);
  console.log("  WARNING: this hands control to NEW_ADMIN. Confirm the address is correct.");
  // Grant new admin first (so we never have zero admins)
  await grant(DEFAULT_ADMIN_ROLE, NEW_ADMIN, "DEFAULT_ADMIN_ROLE → new");
  await grant(ADMIN_ROLE, NEW_ADMIN, "ADMIN_ROLE → new");
  await grant(UPGRADER_ROLE, NEW_ADMIN, "UPGRADER_ROLE → new");
  // Then renounce the deployer's roles
  await renounce(UPGRADER_ROLE, "UPGRADER_ROLE");
  await renounce(ADMIN_ROLE, "ADMIN_ROLE");
  await renounce(DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE");
  console.log("  ✅ deployer no longer holds admin roles");
} else {
  console.log("\n[skip rotation] no NEW_ADMIN set");
}

// ── Final state ───────────────────────────────────────────────────────
console.log("\n════════════════════════════════════════════");
console.log(" Post-deploy state");
console.log("════════════════════════════════════════════");
const oraclePrice = await pub.readContract({
  address: VAULT,
  abi: VAULT_ABI,
  functionName: "getOraclePrice",
});
log("getOraclePrice:", `${oraclePrice} (=$${Number(oraclePrice) / 1e18})`);
const finalPositions = await pub.readContract({
  address: VAULT,
  abi: VAULT_ABI,
  functionName: "getPositionCount",
});
log("positions:", finalPositions);
for (const [role, name] of [
  [DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE deployer"],
  [ADMIN_ROLE, "ADMIN_ROLE deployer"],
  [UPGRADER_ROLE, "UPGRADER_ROLE deployer"],
]) {
  const has = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "hasRole",
    args: [role, account.address],
  });
  log(`${name}:`, has);
}
if (GUARDIAN) {
  const has = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "hasRole",
    args: [GUARDIAN_ROLE, GUARDIAN],
  });
  log("GUARDIAN_ROLE guardian:", has);
}
if (KEEPER) {
  const has = await pub.readContract({
    address: VAULT,
    abi: VAULT_ABI,
    functionName: "hasRole",
    args: [CLAIM_OPERATOR_ROLE, KEEPER],
  });
  log("CLAIM_OPERATOR_ROLE keeper:", has);
}
console.log("════════════════════════════════════════════");
