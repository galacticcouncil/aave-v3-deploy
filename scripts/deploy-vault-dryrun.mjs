// Dry-run HDCL Vault deploy against a chopsticks mainnet fork.
//
// Foundry's forge script can't traverse chopsticks's lazy-loaded storage
// through the Decentral pool's delegatecall (the staticcall returns Stop
// even though direct eth_call works) — so we port Deploy.s.sol to viem,
// which has been validated end-to-end via the chopsticks 2.2.0 release.
//
// Mirrors hdcl-vault/script/Deploy.s.sol step-by-step:
//   1. Deploy QueueLib library
//   2. Link the QueueLib placeholder in HDCLVault bytecode
//   3. Deploy HDCLVault implementation
//   4. Deploy ERC1967Proxy with initialize() call as initdata
//   5. Deploy WDCLOracle(vault)
//   6. vault.setOracle(oracle)  (deployer must == admin)
//   7. Sanity-check vault.getOraclePrice() > 0
//
// Usage:
//   node scripts/deploy-vault-dryrun.mjs

import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  encodeFunctionData,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = "http://localhost:8000";
// Hardhat dev #0 — deployer == admin (Deploy.s.sol:48 requirement)
const PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

// Hydration mainnet addresses — same constants as Deploy.s.sol:11-14
const DECENTRAL_POOL = "0x207a626c07b73E76134177D1f44B0f32e94ADB5a";
const POOL_TOKEN = "0xC91808c129C9766b13D22c9f0cD53Db459c0bc48";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const TVL_CAP = 2_000_000n * 10n ** 18n; // 2M HOLLAR
const QUEUE_LIB_PLACEHOLDER = "__$613e6a1b40d495099704d6df6019b2979e$__";

const VAULT_DIR = "/home/mrq/git/aave-v3-deploy/hdcl-vault";

const queueLibArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/QueueLib.sol/QueueLib.json`, "utf-8"),
);
const vaultArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/HDCLVault.sol/HDCLVault.json`, "utf-8"),
);
const proxyArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/ERC1967Proxy.sol/ERC1967Proxy.json`, "utf-8"),
);
const oracleArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/WDCLOracle.sol/WDCLOracle.json`, "utf-8"),
);

const chain = {
  id: 222222,
  name: "hydration-chopsticks",
  nativeCurrency: { name: "WETH", symbol: "WETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
};

const account = privateKeyToAccount(PK);
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ chain, account, transport: http(RPC) });

// Hydration's pallet-ethereum on mainnet rejects EIP-1559 (type-2) txs —
// per hdcl-vault/deployments/lark-2.md: "Hydration's EVM runs in legacy
// (type-0) tx mode. Don't send EIP-1559 (type-2) transactions — they'll
// be rejected." Forge handled this via --legacy; viem needs it explicitly
// via `type: "legacy"` + `gasPrice`. The price MUST be ≥ DynamicEvmFee's
// current quote (~3.78M wei on mainnet, vs 1.5M on lark testnet); query
// it at runtime so we don't pin a stale value.
const networkGasPrice = await pub.getGasPrice();
const GAS_PRICE = (networkGasPrice * 110n) / 100n; // +10% headroom
console.log(`network gasPrice: ${networkGasPrice}  using: ${GAS_PRICE}`);
// HDCLVault impl is ~24KB and lives near EIP-170. Hydration's per-tx gas
// cap is below the 60M block-gas-limit — empirically 12M works, 18M does
// not (validate returns custom:13).
const txOpts = {
  type: "legacy",
  gas: 12_000_000n,
  gasPrice: GAS_PRICE,
};

console.log("deployer/admin:", account.address);
const bal = await pub.getBalance({ address: account.address });
console.log(`balance: ${bal}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 1: QueueLib
// ════════════════════════════════════════════════════════════════════════
console.log("--- 1: deploy QueueLib ---");
const queueLibHash = await wallet.deployContract({
  abi: queueLibArt.abi,
  bytecode: queueLibArt.bytecode.object,
  ...txOpts,
});
const queueLibReceipt = await pub.waitForTransactionReceipt({ hash: queueLibHash });
const queueLib = queueLibReceipt.contractAddress;
console.log(`  QueueLib: ${queueLib}  gasUsed=${queueLibReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 2: link HDCLVault bytecode (replace QueueLib placeholder)
// ════════════════════════════════════════════════════════════════════════
console.log("--- 2: link QueueLib into HDCLVault bytecode ---");
const linkedBytecode = vaultArt.bytecode.object.replaceAll(
  QUEUE_LIB_PLACEHOLDER,
  queueLib.slice(2).toLowerCase(),
);
const placeholdersLeft = linkedBytecode.match(/__\$[a-f0-9]+\$__/g);
if (placeholdersLeft) {
  console.error("  ❌ unlinked placeholders remain:", placeholdersLeft.slice(0, 3));
  process.exit(1);
}
console.log("  ✅ all QueueLib placeholders linked\n");

// ════════════════════════════════════════════════════════════════════════
// Step 3: HDCLVault implementation
// ════════════════════════════════════════════════════════════════════════
console.log("--- 3: deploy HDCLVault impl ---");
const implHash = await wallet.deployContract({
  abi: vaultArt.abi,
  bytecode: linkedBytecode,
  ...txOpts,
});
const implReceipt = await pub.waitForTransactionReceipt({ hash: implHash });
const impl = implReceipt.contractAddress;
console.log(`  Implementation: ${impl}  gasUsed=${implReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 4: ERC1967Proxy with initialize() initdata
// ════════════════════════════════════════════════════════════════════════
console.log("--- 4: deploy ERC1967Proxy + initialize ---");
const initData = encodeFunctionData({
  abi: vaultArt.abi,
  functionName: "initialize",
  args: [DECENTRAL_POOL, POOL_TOKEN, HOLLAR, TVL_CAP, account.address],
});
console.log(`  initdata length: ${initData.length} chars`);
console.log(`  args: pool=${DECENTRAL_POOL.slice(0, 10)} token=${POOL_TOKEN.slice(0, 10)} hollar=${HOLLAR.slice(0, 10)} cap=2M admin=${account.address.slice(0, 10)}`);
const proxyHash = await wallet.deployContract({
  abi: proxyArt.abi,
  bytecode: proxyArt.bytecode.object,
  args: [impl, initData],
  ...txOpts,
});
const proxyReceipt = await pub.waitForTransactionReceipt({ hash: proxyHash });
if (proxyReceipt.status !== "success") {
  console.error("  ❌ proxy deploy/initialize reverted");
  process.exit(1);
}
const vault = proxyReceipt.contractAddress;
console.log(`  Proxy (Vault): ${vault}  gasUsed=${proxyReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 5: WDCLOracle(vault)
// ════════════════════════════════════════════════════════════════════════
console.log("--- 5: deploy WDCLOracle ---");
const oracleHash = await wallet.deployContract({
  abi: oracleArt.abi,
  bytecode: oracleArt.bytecode.object,
  args: [vault],
  ...txOpts,
});
const oracleReceipt = await pub.waitForTransactionReceipt({ hash: oracleHash });
const oracle = oracleReceipt.contractAddress;
console.log(`  WDCLOracle: ${oracle}  gasUsed=${oracleReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 6: vault.setOracle(oracle)  (deployer holds ADMIN_ROLE per init)
// ════════════════════════════════════════════════════════════════════════
console.log("--- 6: vault.setOracle ---");
const setOracleHash = await wallet.writeContract({
  address: vault,
  abi: parseAbi(["function setOracle(address) external"]),
  functionName: "setOracle",
  args: [oracle],
  ...txOpts,
});
const setOracleReceipt = await pub.waitForTransactionReceipt({ hash: setOracleHash });
console.log(`  status=${setOracleReceipt.status}  gasUsed=${setOracleReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 7: sanity-check oracle wiring
// ════════════════════════════════════════════════════════════════════════
console.log("--- 7: sanity-check getOraclePrice ---");
const oraclePrice = await pub.readContract({
  address: vault,
  abi: parseAbi(["function getOraclePrice() view returns (uint256)"]),
  functionName: "getOraclePrice",
});
console.log(`  getOraclePrice() = ${oraclePrice}`);
if (oraclePrice === 0n) {
  console.error("  ❌ oracle returned 0 — wiring broken");
  process.exit(1);
}
const exchangeRate = await pub.readContract({
  address: vault,
  abi: parseAbi(["function exchangeRate() view returns (uint256)"]),
  functionName: "exchangeRate",
});
console.log(`  exchangeRate() = ${exchangeRate} (=$${Number(exchangeRate) / 1e18})\n`);

console.log("════════════════════════════════════════════");
console.log(" Mainnet-fork dry-run: success");
console.log("════════════════════════════════════════════");
console.log(`  QueueLib:        ${queueLib}`);
console.log(`  Implementation:  ${impl}`);
console.log(`  Proxy (Vault):   ${vault}`);
console.log(`  WDCLOracle:      ${oracle}`);
console.log(`  Admin/deployer:  ${account.address}`);
console.log(`  Network:         chopsticks fork of mainnet (chain 222222)`);
console.log("════════════════════════════════════════════");
