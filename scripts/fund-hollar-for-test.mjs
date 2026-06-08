// Fund an EVM test address with HOLLAR (substrate asset 222) on a
// chopsticks fork via dev_setStorage. Mirrors fund-test-deployer.mjs but
// for HOLLAR instead of WETH.
import { ApiPromise, WsProvider } from "@polkadot/api";
import { hexToU8a, u8aToHex } from "@polkadot/util";

const h160 = process.argv[2] ?? "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const amount = process.argv[3] ?? "1000"; // whole HOLLAR (18 dec)
const WS = "ws://localhost:8000";
const HOLLAR_ASSET = 222;

const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });

const ext = await api.query.evmAccounts.accountExtension(h160);
const bound = ext.isSome;
const accountId = new Uint8Array(32);
if (bound) {
  accountId.set(hexToU8a(h160), 0);
  accountId.set(ext.unwrap().toU8a(), 20);
} else {
  accountId.set([0x45, 0x54, 0x48, 0x00], 0);
  accountId.set(hexToU8a(h160), 4);
}
const ss58 = api.registry.createType("AccountId", accountId).toString();
console.log(`funding ${h160} (${ss58}) with ${amount} HOLLAR`);

const wei = BigInt(amount) * 10n ** 18n;
const accountData = api.registry.createType("OrmlTokensAccountData", {
  free: wei.toString(),
  reserved: "0",
  frozen: "0",
});
const key = api.query.tokens.accounts.key(ss58, HOLLAR_ASSET);
await api._rpcCore.provider.send("dev_setStorage", [[
  [key, u8aToHex(accountData.toU8a())],
]]);

const after = await api.query.tokens.accounts(ss58, HOLLAR_ASSET);
console.log(`HOLLAR balance: ${after.free.toString()} (${BigInt(after.free.toString()) / 10n ** 18n})`);

await api.disconnect();
