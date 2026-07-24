// Smoke-test the tier-1 RPCs added in chopsticks 2.2.0:
//   - eth_getLogs                              (the big one)
//   - eth_feeHistory                           (synthetic, derived from gas price)
//   - eth_maxPriorityFeePerGas                 (synthetic)
//   - eth_getBlockTransactionCountByNumber     (real count)
//   - eth_getBlockTransactionCountByHash       (real count)
//   - eth_getBlockByNumber/Hash with real txs  (was: empty array)
//   - eth_mining / eth_coinbase / eth_hashrate / eth_protocolVersion (stubs)
//
// Setup is the same as scripts/smoke-test-bil-on-chopsticks.mjs — needs a
// chopsticks fork of wss://2.lark.hydration.cloud running on :8000,
// Instant block-build, and a funded deployer.
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  parseAbiItem,
  getAbiItem,
  encodeEventTopics,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = "http://localhost:8000";
const ALICE_PK =
  process.env.PRIV_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

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

let ok = true;
const expect = (label, got, want) => {
  const a = JSON.stringify(got);
  const b = JSON.stringify(want);
  const eq = a === b;
  console.log(`  ${eq ? "✅" : "❌"} ${label}: got ${a}, want ${b}`);
  if (!eq) ok = false;
};

// === Pre: deploy a contract that emits an event ===
// We'll use a tiny EventEmitter: pragma solidity ^0.8; contract X { event
// Ping(address indexed who, uint256 n); function ping(uint256 n) external {
// emit Ping(msg.sender, n); } }
// Bytecode + abi precomputed (no need to invoke solc here).
// Compiled from: contract EventEmitter { event Ping(address indexed who,
// uint256 n); function ping(uint256 n) external { emit Ping(msg.sender, n); } }
// (solc 0.7.3 — keeps bytecode small for the smoke test)
const EMITTER_BYTECODE =
  "0x6080604052348015600f57600080fd5b5060df8061001e6000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c8063773acdef14602d575b600080fd5b605660048036036020811015604157600080fd5b81019080803590602001909291905050506058565b005b3373ffffffffffffffffffffffffffffffffffffffff167ffd8d0c1dc3ab254ec49463a1192bb2423b3b851adedec1aa94dcd362dc063c9d826040518082815260200191505060405180910390a25056fea26469706673582212200df3c488e570a4db921b745f4c6e537e46b9d9c921644e144d658f2a7532068164736f6c63430007030033";
const EMITTER_ABI = parseAbi([
  "function ping(uint256 n) external",
  "event Ping(address indexed who, uint256 n)",
]);
const PING_EVENT = parseAbiItem("event Ping(address indexed who, uint256 n)");

console.log("\n--- deploy EventEmitter ---");
const deployHash = await wallet.deployContract({
  abi: EMITTER_ABI,
  bytecode: EMITTER_BYTECODE,
  gas: 1_500_000n,
  maxFeePerGas: 1_500_000n,
  maxPriorityFeePerGas: 1_500_000n,
});
const dep = await pub.waitForTransactionReceipt({ hash: deployHash });
console.log(`  status=${dep.status} addr=${dep.contractAddress}`);
const emitter = dep.contractAddress;

console.log("\n--- emit 3 events with n = 1, 2, 3 ---");
const emitHashes = [];
for (let i = 1; i <= 3; i++) {
  const h = await wallet.writeContract({
    address: emitter,
    abi: EMITTER_ABI,
    functionName: "ping",
    args: [BigInt(i)],
    gas: 200_000n,
    maxFeePerGas: 1_500_000n,
    maxPriorityFeePerGas: 1_500_000n,
  });
  await pub.waitForTransactionReceipt({ hash: h });
  emitHashes.push(h);
  console.log(`  ping(${i}) tx=${h}`);
}

// Instant block-build is async — even though waitForTransactionReceipt
// returned, chain.head may not have advanced to include the last ping
// yet. Poll until the last ping's receipt block ≤ head.
const lastReceipt = await pub.getTransactionReceipt({ hash: emitHashes[emitHashes.length - 1] });
const targetBlock = lastReceipt.blockNumber;
for (let i = 0; i < 30; i++) {
  const h = await pub.getBlockNumber();
  if (h >= targetBlock) break;
  await new Promise((r) => setTimeout(r, 100));
}

// === Test eth_getLogs ===
console.log("\n--- eth_getLogs: no filter, range = last 10 blocks ---");
const head = await pub.getBlockNumber();
console.log(`  head=${head} (last ping at block ${targetBlock})`);
const allLogs = await pub.getLogs({ fromBlock: head - 10n, toBlock: head });
console.log(`  logs returned: ${allLogs.length}`);
expect("found at least 3 logs", allLogs.length >= 3, true);

console.log("\n--- eth_getLogs: address filter ---");
const byAddr = await pub.getLogs({ address: emitter, fromBlock: head - 10n, toBlock: head });
console.log(`  logs from ${emitter}: ${byAddr.length}`);
expect("3 logs from emitter", byAddr.length, 3);

console.log("\n--- eth_getLogs: topic filter (Ping events only) ---");
const pingTopics = encodeEventTopics({ abi: EMITTER_ABI, eventName: "Ping" });
const byTopic = await pub.getLogs({
  fromBlock: head - 10n,
  toBlock: head,
  topics: pingTopics,
});
console.log(`  logs matching Ping(): ${byTopic.length}`);
// >= 3 because previous test runs may have left other Ping emitters in
// the chopsticks fork's state. The point is that the topic filter is
// applied (we don't see other event types in there).
expect("≥3 Ping logs", byTopic.length >= 3, true);
expect(
  "all logs have the Ping signature topic",
  byTopic.every((l) => l.topics[0] === pingTopics[0]),
  true,
);

console.log("\n--- eth_getLogs: address + indexed-arg topic filter (sender = deployer) ---");
const byBoth = await pub.getLogs({
  address: emitter,
  fromBlock: head - 10n,
  toBlock: head,
  event: PING_EVENT,
  args: { who: account.address },
});
console.log(`  decoded logs (who=deployer): ${byBoth.length}`);
expect("3 events", byBoth.length, 3);
expect(
  "args.n values",
  byBoth.map((l) => l.args.n.toString()).sort(),
  ["1", "2", "3"],
);

// viem strips unknown-signature topics from eth_getLogs (validates
// against known event ABIs), so to test the non-match path on the
// handler we issue the raw RPC ourselves.
console.log("\n--- eth_getLogs: address + non-matching topic (raw RPC) ---");
const noneByTopicResp = await fetch(RPC, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getLogs",
    params: [{
      address: emitter,
      fromBlock: `0x${(head - 10n).toString(16)}`,
      toBlock: `0x${head.toString(16)}`,
      topics: ["0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"],
    }],
  }),
}).then((r) => r.json());
expect("no logs", noneByTopicResp.result.length, 0);

// === Block tx-count ===
console.log("\n--- eth_getBlockTransactionCountByNumber ---");
const blkWithTx = await pub.getBlock({ blockNumber: head });
console.log(`  head block has ${blkWithTx.transactions.length} txs`);
expect("head block has >= 1 tx", blkWithTx.transactions.length >= 1, true);

const countResp = await fetch(RPC, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getBlockTransactionCountByNumber",
    params: ["0x" + head.toString(16)],
  }),
}).then((r) => r.json());
console.log(`  eth_getBlockTransactionCountByNumber: ${countResp.result}`);
expect("count matches block.transactions", Number(countResp.result), blkWithTx.transactions.length);

console.log("\n--- eth_getBlockByHash with fullTransactions=true ---");
const fullBlk = await pub.getBlock({ blockHash: blkWithTx.hash, includeTransactions: true });
console.log(`  full-tx block has ${fullBlk.transactions.length} txs`);
const firstTx = fullBlk.transactions[0];
console.log(`  first tx: hash=${firstTx.hash} from=${firstTx.from} to=${firstTx.to}`);
expect(
  "first tx has hash + from",
  typeof firstTx === "object" && !!firstTx.hash && !!firstTx.from,
  true,
);

// === Fee history & priority fee ===
console.log("\n--- eth_maxPriorityFeePerGas ---");
const mpfgResp = await fetch(RPC, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_maxPriorityFeePerGas",
    params: [],
  }),
}).then((r) => r.json());
console.log(`  eth_maxPriorityFeePerGas: ${mpfgResp.result}`);
expect("priority fee is a hex string", typeof mpfgResp.result === "string" && mpfgResp.result.startsWith("0x"), true);

console.log("\n--- eth_feeHistory (5 blocks back) ---");
const fh = await pub.getFeeHistory({ blockCount: 5, rewardPercentiles: [25, 50, 75] });
console.log(`  oldestBlock=${fh.oldestBlock} baseFee[0]=${fh.baseFeePerGas[0]}`);
expect("baseFeePerGas len 6", fh.baseFeePerGas.length, 6); // blockCount + 1
expect("gasUsedRatio len 5", fh.gasUsedRatio.length, 5);

// === Trivial stubs ===
console.log("\n--- trivial stubs ---");
for (const m of ["eth_mining", "eth_coinbase", "eth_hashrate", "eth_protocolVersion"]) {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: m, params: [] }),
  }).then((r) => r.json());
  console.log(`  ${m}: ${JSON.stringify(r.result)}`);
  expect(`${m} returns something`, r.result !== undefined && r.error === undefined, true);
}

console.log(ok ? "\n🎉 all tier-1 checks passed" : "\n❌ some checks failed");
process.exit(ok ? 0 : 1);
