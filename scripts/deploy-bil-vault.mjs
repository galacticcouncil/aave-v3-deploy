// BIL Vault deploy (works against any RPC: mainnet, lark, chopsticks fork) against a chopsticks mainnet fork.
//
// Foundry's forge script can't traverse chopsticks's lazy-loaded storage
// through the Decentral pool's delegatecall (the staticcall returns Stop
// even though direct eth_call works) — so we port Deploy.s.sol to viem,
// which has been validated end-to-end via the chopsticks 2.2.0 release.
//
// Mirrors bil-vault/script/Deploy.s.sol step-by-step:
//   1. Deploy QueueLib library
//   2. Link the QueueLib placeholder in BILVault bytecode
//   3. Deploy BILVault implementation
//   4. Deploy ERC1967Proxy with initialize() call as initdata
//   5. Deploy BILOracle(vault)
//   6. vault.setOracle(oracle)  (deployer must == admin)
//   7. Sanity-check vault.getOraclePrice() > 0
//
// Usage:
//   node scripts/deploy-bil-vault.mjs

import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  encodeFunctionData,
  encodeDeployData,
  parseTransaction,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = process.env.RPC ?? "http://localhost:8000";
// Deployer == admin (Deploy.s.sol:48 requirement). Defaults to hardhat dev
// #0 for chopsticks; override via PRIVATE_KEY or PRIV_KEY for mainnet/lark.
const PK =
  process.env.PRIVATE_KEY ??
  process.env.PRIV_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

// Hydration mainnet addresses — same constants as Deploy.s.sol:11-14
const DECENTRAL_POOL = "0x207a626c07b73E76134177D1f44B0f32e94ADB5a";
const POOL_TOKEN = "0xC91808c129C9766b13D22c9f0cD53Db459c0bc48";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const TVL_CAP = 2_000_000n * 10n ** 18n; // 2M HOLLAR
const QUEUE_LIB_PLACEHOLDER = "__$613e6a1b40d495099704d6df6019b2979e$__";

const VAULT_DIR = "/home/mrq/git/aave-v3-deploy/bil-vault";

const queueLibArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/QueueLib.sol/QueueLib.json`, "utf-8"),
);
const vaultArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/BILVault.sol/BILVault.json`, "utf-8"),
);
const proxyArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/ERC1967Proxy.sol/ERC1967Proxy.json`, "utf-8"),
);
const oracleArt = JSON.parse(
  readFileSync(`${VAULT_DIR}/out/BILOracle.sol/BILOracle.json`, "utf-8"),
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
// per bil-vault/deployments/lark-2.md: "Hydration's EVM runs in legacy
// (type-0) tx mode. Don't send EIP-1559 (type-2) transactions — they'll
// be rejected." Forge handled this via --legacy; viem needs it explicitly
// via `type: "legacy"` + `gasPrice`. The price MUST be ≥ DynamicEvmFee's
// current quote (~3.78M wei on mainnet, vs 1.5M on lark testnet); query
// it at runtime so we don't pin a stale value.
const networkGasPrice = await pub.getGasPrice();
const GAS_PRICE = (networkGasPrice * 110n) / 100n; // +10% headroom
console.log(`network gasPrice: ${networkGasPrice}  using: ${GAS_PRICE}`);
// BILVault impl is ~24KB and lives near EIP-170. Hydration's per-tx gas
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

// Frontier's `ethereum.transact` decoder requires the ECDSA r and s to each
// serialize to a full 32 bytes. viem (RLP) encodes them minimally, so when r
// or s has a zero high byte (~1/256 chance each) the raw tx is rejected with
// "failed on r/s: H256: Expected input with 32 bytes, found 31 bytes". ECDSA
// is deterministic (RFC 6979), so re-signing the SAME tx reproduces the same
// bad signature — on an idle chain that means a permanent stall. We instead
// sign locally, check both r and s are full-width, and nudge gasPrice by 1 wei
// per retry (changing the signed payload) until the signature is clean, then
// broadcast the raw tx ourselves. Nonce is managed locally so a rejected
// candidate never consumes it.
let _nonce = await pub.getTransactionCount({
  address: account.address,
  blockTag: "pending",
});

const _fullWidthSig = (sig) =>
  BigInt(sig.r) >> 248n !== 0n && BigInt(sig.s) >> 248n !== 0n;

async function _sendSafe(data, to) {
  const nonce = _nonce++;
  for (let i = 0; i < 64; i++) {
    const req = {
      ...(to ? { to } : {}),
      data,
      value: 0n,
      gas: txOpts.gas,
      gasPrice: GAS_PRICE + BigInt(i), // nudge payload until r,s are 32 bytes
      nonce,
      type: "legacy",
      chainId: chain.id,
    };
    const signed = await account.signTransaction(req);
    if (_fullWidthSig(parseTransaction(signed))) {
      if (i > 0) console.log(`  (re-signed ${i}x for full-width signature)`);
      return await wallet.sendRawTransaction({ serializedTransaction: signed });
    }
  }
  throw new Error(
    "could not produce a 32-byte r,s signature after 64 gasPrice nudges"
  );
}

async function deploySafe(abi, bytecode, args = []) {
  const data = encodeDeployData({ abi, bytecode, args });
  const hash = await _sendSafe(data, undefined);
  return await pub.waitForTransactionReceipt({ hash });
}

async function writeSafe(address, abi, functionName, args = []) {
  const data = encodeFunctionData({ abi, functionName, args });
  const hash = await _sendSafe(data, address);
  return await pub.waitForTransactionReceipt({ hash });
}

// ════════════════════════════════════════════════════════════════════════
// Step 1: QueueLib
// ════════════════════════════════════════════════════════════════════════
console.log("--- 1: deploy QueueLib ---");
const queueLibReceipt = await deploySafe(
  queueLibArt.abi,
  queueLibArt.bytecode.object
);
const queueLib = queueLibReceipt.contractAddress;
console.log(`  QueueLib: ${queueLib}  gasUsed=${queueLibReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 2: link BILVault bytecode (replace QueueLib placeholder)
// ════════════════════════════════════════════════════════════════════════
console.log("--- 2: link QueueLib into BILVault bytecode ---");
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
// Step 3: BILVault implementation
// ════════════════════════════════════════════════════════════════════════
console.log("--- 3: deploy BILVault impl ---");
const implReceipt = await deploySafe(vaultArt.abi, linkedBytecode);
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
const proxyReceipt = await deploySafe(proxyArt.abi, proxyArt.bytecode.object, [
  impl,
  initData,
]);
if (proxyReceipt.status !== "success") {
  console.error("  ❌ proxy deploy/initialize reverted");
  process.exit(1);
}
const vault = proxyReceipt.contractAddress;
console.log(`  Proxy (Vault): ${vault}  gasUsed=${proxyReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 5: BILOracle(vault)
// ════════════════════════════════════════════════════════════════════════
console.log("--- 5: deploy BILOracle ---");
const oracleReceipt = await deploySafe(oracleArt.abi, oracleArt.bytecode.object, [
  vault,
]);
const oracle = oracleReceipt.contractAddress;
console.log(`  BILOracle: ${oracle}  gasUsed=${oracleReceipt.gasUsed}\n`);

// ════════════════════════════════════════════════════════════════════════
// Step 6: vault.setOracle(oracle)  (deployer holds ADMIN_ROLE per init)
// ════════════════════════════════════════════════════════════════════════
console.log("--- 6: vault.setOracle ---");
const setOracleReceipt = await writeSafe(
  vault,
  parseAbi(["function setOracle(address) external"]),
  "setOracle",
  [oracle]
);
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
console.log(`  BILOracle:      ${oracle}`);
console.log(`  Admin/deployer:  ${account.address}`);
console.log(`  Network:         chopsticks fork of mainnet (chain 222222)`);
console.log("════════════════════════════════════════════");
