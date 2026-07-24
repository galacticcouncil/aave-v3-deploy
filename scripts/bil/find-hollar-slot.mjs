// Find HOLLAR's ERC20 _balances slot on the chopsticks fork by writing a
// sentinel to candidate slots via pallet-evm AccountStorages and checking
// whether balanceOf() reflects it (authoritative — uses EVM execution).
import { ApiPromise, WsProvider } from "@polkadot/api";
import { ethers } from "ethers";

const WS = "ws://localhost:8000";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const USER = process.env.USER_H160 ?? "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const SENTINEL = 123456789n * 10n ** 18n;

const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
const p = new ethers.providers.JsonRpcProvider("http://localhost:8000");
const hollar = new ethers.Contract(HOLLAR, ["function balanceOf(address) view returns (uint256)"], p);
const ac = new ethers.utils.AbiCoder();

const candidates = [0,1,2,3,4,5,6,7,8,9,10,11,12,50,51,52,53,54,55,101,102,151,152,201,202,251,252];
const valHex = "0x" + SENTINEL.toString(16).padStart(64, "0");
let found = null;

for (const slot of candidates) {
  const key = ethers.utils.keccak256(ac.encode(["address","uint256"], [USER, slot]));
  const storageKey = api.query.evm.accountStorages.key(HOLLAR, key);
  await api._rpcCore.provider.send("dev_setStorage", [[[storageKey, valHex]]]);
  const bal = (await hollar.balanceOf(USER)).toString();
  if (bal === SENTINEL.toString()) { found = slot; console.log(`SLOT FOUND: ${slot}`); break; }
  // reset
  await api._rpcCore.provider.send("dev_setStorage", [[[storageKey, "0x" + "0".repeat(64)]]]);
}

if (found === null) console.log("no slot matched in candidate set");
else console.log(`_balances slot = ${found}`);
await api.disconnect();
