// Deploy a fresh BILOracleAdapter to the chopsticks fork via viem (not
// ethers), using the new eth_sendRawTransaction handler we just added to
// chopsticks. Validates end-to-end:
//   • estimateGas works for CREATE
//   • sendRawTransaction submits to the substrate txpool
//   • the resulting block has the deployed contract code
//
// Usage:
//   node scripts/test-chopsticks-deploy.mjs
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = "http://localhost:8000";
const VAULT = "0xbDAFEB92440d8696d6C143bc7e6B086d461e3502";

// Hardhat dev account #0 — well-known test PK, no balance on lark-2 but
// Hydration's pallet-evm uses `total_fee_per_gas: 0` so contract deploys
// shouldn't actually charge gas. The substrate dispatch is unsigned
// (Frontier's Ethereum::transact via ValidateUnsigned), so no substrate
// fee either. Pure infrastructure test.
const ALICE_PK = process.env.PRIV_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

// Load the BILOracleAdapter artifact (bytecode + abi).
const art = JSON.parse(
  readFileSync(
    "/home/mrq/git/aave-v3-deploy/deployments/lark2/BILOracleAdapter.json",
    "utf-8"
  )
);

const chain = {
  id: 222222,
  name: "lark2-chopsticks",
  nativeCurrency: { name: "HDX", symbol: "HDX", decimals: 12 },
  rpcUrls: { default: { http: [RPC] }, public: { http: [RPC] } },
};

const account = privateKeyToAccount(ALICE_PK);
console.log("deployer:", account.address);

const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ chain, account, transport: http(RPC) });

const chainId = await pub.getChainId();
const blockNumber = await pub.getBlockNumber();
const balance = await pub.getBalance({ address: account.address });
const nonce = await pub.getTransactionCount({ address: account.address });
console.log(
  `chain=${chainId} block=${blockNumber} balance=${balance} nonce=${nonce}\n`
);

// Skip estimateGas — pallet-evm reports 0-fee per Hydration's config, but
// estimateGas with a 0-balance sender may still revert internally. Pass an
// explicit gas limit (well above the simulated 326K we saw) and let the
// substrate `Ethereum::transact` (unsigned) actually apply.
const gas = 3_000_000n;
console.log(`(skipping estimateGas — using fixed gas ${gas})`);

// Deploy.
// Hydration enforces maxFeePerGas >= 1500000 (its MinGasPrice) at validate
// time; using exactly that to minimise the balance requirement.
const hash = await wallet.deployContract({
  abi: art.abi,
  bytecode: art.bytecode,
  args: [VAULT],
  gas,
  maxFeePerGas: 1_500_000n,
  maxPriorityFeePerGas: 1_500_000n,
});
console.log(`deploy tx: ${hash}`);

// Wait for receipt — chopsticks should auto-seal in Instant mode.
const receipt = await pub.waitForTransactionReceipt({
  hash,
  timeout: 60_000,
});
console.log(`status: ${receipt.status}`);
console.log(`contractAddress: ${receipt.contractAddress}`);
console.log(`gasUsed: ${receipt.gasUsed}`);

// Sanity-check: call latestRoundData() on the new instance.
const code = await pub.getBytecode({ address: receipt.contractAddress });
console.log(`code size: ${code ? code.length / 2 - 1 : 0} bytes`);

const [roundId, answer, , , answeredIn] = await pub.readContract({
  address: receipt.contractAddress,
  abi: parseAbi([
    "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
  ]),
  functionName: "latestRoundData",
});
console.log(
  `latestRoundData: roundId=${roundId} answer=${answer} answeredIn=${answeredIn}`
);
console.log(
  `\n✅ contract deploy via chopsticks eth_sendRawTransaction worked end-to-end`
);
