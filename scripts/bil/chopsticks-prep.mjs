// Prep the chopsticks fork for BIL deploy:
//  - Instant block build mode (so EVM txs auto-mine)
//  - fund deployer's EVM-truncated SS58 with WETH (asset 20) for gas
//  - fund Alice with WETH too (harmless; some flows need it)
//  - whitelist deployer H160 as a contract creator (evmAccounts.contractDeployer)
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { hexToU8a } from "@polkadot/util";
import { encodeAddress } from "@polkadot/util-crypto";

const WS = process.env.WS_URL ?? "ws://localhost:8000";
const DEPLOYER_H160 = process.env.DEPLOYER_EVM ?? "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const WETH_ASSET_ID = 20;
const PREFIX = 63;
const BIG = 1_000_000n * 10n ** 18n; // 1M WETH, plenty for gas

function evmToTruncatedSs58(evm) {
  const buf = new Uint8Array(32);
  buf[0] = 0x45; buf[1] = 0x54; buf[2] = 0x48; buf[3] = 0x00; // "ETH\0"
  buf.set(hexToU8a(evm), 4);
  return encodeAddress(buf, PREFIX);
}

const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });

// 1) Instant build mode
try {
  await api._rpcCore.provider.send("dev_setBlockBuildMode", ["Instant"]);
  console.log("build mode -> Instant");
} catch (e) { console.log("setBlockBuildMode:", e.message); }

// 2) fund WETH via dev_setStorage on tokens.accounts
const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
const deployerSs58 = evmToTruncatedSs58(DEPLOYER_H160);
const targets = [
  ["deployer", deployerSs58],
  ["alice", alice.address],
];
const entries = [];
for (const [, addr] of targets) {
  const key = api.query.tokens.accounts.key(addr, WETH_ASSET_ID);
  const val = api.createType("OrmlTokensAccountData", { free: BIG, reserved: 0, frozen: 0 }).toHex();
  entries.push([key, val]);
}
await api._rpcCore.provider.send("dev_setStorage", [entries]);
console.log("funded WETH:", targets.map((t) => t[0]).join(", "));

// 3) whitelist deployer as contract creator
const wlKey = api.query.evmAccounts.contractDeployer.key(DEPLOYER_H160);
await api._rpcCore.provider.send("dev_setStorage", [[[wlKey, "0x"]]]);

// verify
const dw = await api.query.tokens.accounts(deployerSs58, WETH_ASSET_ID);
const aw = await api.query.tokens.accounts(alice.address, WETH_ASSET_ID);
const wl = await api.query.evmAccounts.contractDeployer(DEPLOYER_H160);
console.log(`deployer ss58: ${deployerSs58}`);
console.log(`deployer WETH: ${dw.free.toString()}`);
console.log(`alice WETH:    ${aw.free.toString()}`);
console.log(`whitelisted:   ${wl.toHuman()}`);
await api.disconnect();
