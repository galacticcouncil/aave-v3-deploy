// Smoke-test: deploy BILOracleAdapter on chopsticks via viem (using the
// new eth_sendRawTransaction + eth_getTransactionReceipt RPCs), then call
// its state-independent getters AND state-dependent ones that
// delegate-call into the live forked BIL vault. End-to-end exercise of
// the new chopsticks RPC surface against real on-chain state.
//
// Requires a chopsticks fork of `wss://2.lark.hydration.cloud` running on
// :8000 (that's where the BIL vault is deployed — NOT 0.lark).
//
// Usage:
//   node scripts/smoke-test-bil-on-chopsticks.mjs
import { readFileSync } from "fs";
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = "http://localhost:8000";
const ALICE_PK =
  process.env.PRIV_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// Pass any 20-byte address as the vault — getters don't dereference it.
const VAULT = "0xbDAFEB92440d8696d6C143bc7e6B086d461e3502";

const art = JSON.parse(
  readFileSync(
    "/home/mrq/git/aave-v3-deploy/deployments/lark2/BILOracleAdapter.json",
    "utf-8",
  ),
);

const chain = {
  id: 222222,
  name: "lark2-chopsticks",
  nativeCurrency: { name: "HDX", symbol: "HDX", decimals: 12 },
  rpcUrls: { default: { http: [RPC] }, public: { http: [RPC] } },
};

const account = privateKeyToAccount(ALICE_PK);
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ chain, account, transport: http(RPC) });

console.log("deployer:", account.address);
const balance = await pub.getBalance({ address: account.address });
const nonce = await pub.getTransactionCount({ address: account.address });
console.log(`balance=${balance}  nonce=${nonce}\n`);

// === Phase 1: deploy ============================================
console.log("--- phase 1: deploy BILOracleAdapter ---");
const deployHash = await wallet.deployContract({
  abi: art.abi,
  bytecode: art.bytecode,
  args: [VAULT],
  gas: 3_000_000n,
  maxFeePerGas: 1_500_000n,
  maxPriorityFeePerGas: 1_500_000n,
});
console.log(`deploy tx: ${deployHash}`);

const deployRct = await pub.waitForTransactionReceipt({ hash: deployHash, timeout: 60_000 });
console.log(`  status=${deployRct.status} contract=${deployRct.contractAddress} gasUsed=${deployRct.gasUsed}`);
if (deployRct.status !== "success") {
  console.log("❌ deploy failed");
  process.exit(1);
}
const adapter = deployRct.contractAddress;

// === Phase 2: view-call the immutable getters ===================
console.log("\n--- phase 2: read state-independent getters ---");
const abi = parseAbi([
  "function version() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function description() view returns (string)",
  "function vault() view returns (address)",
]);
const version = await pub.readContract({ address: adapter, abi, functionName: "version" });
const decimals = await pub.readContract({ address: adapter, abi, functionName: "decimals" });
const description = await pub.readContract({ address: adapter, abi, functionName: "description" });
const vault = await pub.readContract({ address: adapter, abi, functionName: "vault" });
console.log(`  version=${version}  decimals=${decimals}  description="${description}"`);
console.log(`  vault=${vault}`);

// Assertions
let ok = true;
const expect = (label, got, want) => {
  const eq = got.toString().toLowerCase() === want.toString().toLowerCase();
  console.log(`  ${eq ? "✅" : "❌"} ${label}: got ${got}, want ${want}`);
  if (!eq) ok = false;
};
expect("version", version, 4n);
expect("decimals", decimals, 8);
expect("description", description, "BIL / USD");
expect("vault", vault, VAULT);

// === Phase 3: confirm eth_getTransactionByHash works ============
console.log("\n--- phase 3: eth_getTransactionByHash on the deploy tx ---");
const tx = await pub.getTransaction({ hash: deployHash });
console.log(`  type=${tx.type}  from=${tx.from}  to=${tx.to}  nonce=${tx.nonce}  gas=${tx.gas}`);
expect("tx.from", tx.from.toLowerCase(), account.address.toLowerCase());
expect("tx.to", String(tx.to), "null");

// === Phase 4: read-call into live forked vault state via the adapter ===
// adapter.latestRoundData() reads vault.exchangeRate() — proves the
// chopsticks fork preserves the live vault's storage and eth_call works
// across contract boundaries.
console.log("\n--- phase 4: read live forked vault state via adapter ---");
const lrdAbi = parseAbi([
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
  "function latestAnswer() view returns (int256)",
]);
const [roundId, answer, , updatedAt, answeredInRound] = await pub.readContract({
  address: adapter,
  abi: lrdAbi,
  functionName: "latestRoundData",
});
const latestAnswer = await pub.readContract({
  address: adapter,
  abi: lrdAbi,
  functionName: "latestAnswer",
});
console.log(`  latestRoundData: roundId=${roundId} answer=${answer} updatedAt=${updatedAt} answeredIn=${answeredInRound}`);
console.log(`  latestAnswer (8-decimals): ${latestAnswer} = $${Number(latestAnswer) / 1e8}`);
// exchangeRate ≈ 1.008e18 → /1e10 → ≈ 1.008e8 → ~$1.008. Assert it's
// roughly $1 (between 0.95 and 1.10) since yield should keep it close.
const answerNum = Number(latestAnswer);
const inRange = answerNum >= 95_000_000 && answerNum <= 110_000_000;
console.log(`  ${inRange ? "✅" : "❌"} latestAnswer in $0.95–$1.10 range`);
if (!inRange) ok = false;

// === Phase 5: send a state-changing tx (self-transfer 0 WETH) ===
// Confirms eth_sendRawTransaction + receipt work for non-CREATE calls.
console.log("\n--- phase 5: state-changing CALL (zero self-transfer) ---");
const xferHash = await wallet.sendTransaction({
  to: account.address,
  value: 0n,
  gas: 100_000n,
  maxFeePerGas: 1_500_000n,
  maxPriorityFeePerGas: 1_500_000n,
});
console.log(`xfer tx: ${xferHash}`);
const xferRct = await pub.waitForTransactionReceipt({ hash: xferHash, timeout: 60_000 });
console.log(`  status=${xferRct.status} gasUsed=${xferRct.gasUsed}`);
expect("xfer.status", xferRct.status, "success");

const newNonce = await pub.getTransactionCount({ address: account.address });
console.log(`  sender nonce: ${nonce} → ${newNonce}`);
expect("nonce incremented", newNonce, nonce + 2);

console.log(ok ? "\n🎉 all checks passed" : "\n❌ some checks failed");
process.exit(ok ? 0 : 1);
