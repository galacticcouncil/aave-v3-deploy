// Fund a fresh test EVM address on a Hydration chopsticks fork. Per
// memory/chopsticks-evm-funding.md, pallet-evm's `Config::Currency` is
// `WethCurrency = CurrencyAdapter<Runtime, WethAssetId>` (asset 20 = WETH),
// not pallet-balances. So `eth_getBalance(h160)` reads
// `Tokens.Accounts[<substrate>, 20]`. We also keep System.Account[ss58]
// alive (providers≥1) so the account isn't treated as non-existent.
//
// Usage:
//   node scripts/fund-test-deployer.mjs [h160]
//
// Defaults to hardhat dev #0.

import { ApiPromise, WsProvider } from "@polkadot/api";
import { hexToU8a, u8aToHex } from "@polkadot/util";

const h160 = process.argv[2] ?? "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const WS = "ws://localhost:8000";
const WETH_ASSET = 20;

const api = await ApiPromise.create({ provider: new WsProvider(WS) });

// 1. Is this H160 bound to a substrate account via evm-accounts?
const ext = await api.query.evmAccounts.accountExtension(h160);
const bound = ext.isSome;
console.log(`bound: ${bound}`);

// 2. Compute the mapped substrate AccountId.
const accountId = new Uint8Array(32);
if (bound) {
  accountId.set(hexToU8a(h160), 0);
  accountId.set(ext.unwrap().toU8a(), 20);
} else {
  // ExtendedAddressMapping unbound layout: b"ETH\0" + h160 + 8 zero bytes.
  accountId.set([0x45, 0x54, 0x48, 0x00], 0);
  accountId.set(hexToU8a(h160), 4);
}
const ss58 = api.registry.createType("AccountId", accountId).toString();
console.log(`H160 ${h160}`);
console.log(`  → substrate AccountId ${ss58}`);
console.log(`  → raw bytes ${u8aToHex(accountId)}`);

// 3. Fund Tokens.Accounts[ss58, 20] with 1000 WETH (10^18 base units * 1000).
const WETH_FREE = 10n ** 21n; // 1000 WETH (WETH has 18 decimals on Hydration)
const accountData = api.registry.createType("OrmlTokensAccountData", {
  free: WETH_FREE.toString(),
  reserved: "0",
  frozen: "0",
});
const tokensKey = api.query.tokens.accounts.key(ss58, WETH_ASSET);

// 4. Ensure System.Account[ss58] exists with providers≥1 so the account is
//    "alive" — pallet-evm rejects sub-call from non-existent accounts.
const info = api.registry.createType("AccountInfo", {
  nonce: 0,
  consumers: 0,
  providers: 1,
  sufficients: 1,
  data: { free: "0", reserved: "0", frozen: "0", flags: "0" },
});
const systemKey = api.query.system.account.key(ss58);

await api._rpcCore.provider.send("dev_setStorage", [[
  [tokensKey, u8aToHex(accountData.toU8a())],
  [systemKey, u8aToHex(info.toU8a())],
]]);

// 5. Verify via the storage we just set and via eth_getBalance.
const tokAfter = await api.query.tokens.accounts(ss58, WETH_ASSET);
console.log(`tokens[20].free: ${tokAfter.free.toString()}`);
const sysAfter = await api.query.system.account(ss58);
console.log(`system.account providers: ${sysAfter.providers.toString()}`);

const ethBalanceResp = await fetch("http://localhost:8000", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getBalance",
    params: [h160, "latest"],
  }),
}).then((r) => r.json());
console.log(`eth_getBalance(${h160}) = ${ethBalanceResp.result}`);

await api.disconnect();
