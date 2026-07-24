// Get BIL: fund a wallet with HOLLAR, then zap-deposit → hold BIL (aToken).
import { ethers } from "ethers";
import { ApiPromise, WsProvider } from "@polkadot/api";

const RPC = "http://localhost:8000";
const PK = process.env.PK ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const ZAP = "0x4826533B4897376654Bb4d4AD88B7faFD0C98528";
const ABIL = "0x30D8FC13FAb2491347395789e82cCF3F62Aa2e01";
const AMT = BigInt(process.env.AMT ?? "10000") * 10n ** 18n;

const p = new ethers.providers.JsonRpcProvider(RPC);
const w = new ethers.Wallet(PK, p);
const me = w.address;
const f = (x) => ethers.utils.formatUnits(x, 18);

const api = await ApiPromise.create({ provider: new WsProvider("ws://localhost:8000"), noInitWarn: true });
const ac = new ethers.utils.AbiCoder();
const bkey = ethers.utils.keccak256(ac.encode(["address", "uint256"], [me, 3]));
await api._rpcCore.provider.send("dev_setStorage", [[[api.query.evm.accountStorages.key(HOLLAR, bkey), "0x" + (AMT + 5000n * 10n ** 18n).toString(16).padStart(64, "0")]]]);
await api.disconnect();

const h = new ethers.Contract(HOLLAR, ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"], w);
const abil = new ethers.Contract(ABIL, ["function balanceOf(address) view returns (uint256)"], p);
console.log("wallet:", me);
console.log("HOLLAR:", f(await h.balanceOf(me)));
console.log("BIL before:", f(await abil.balanceOf(me)));

const OVR = { gasLimit: 5000000, gasPrice: 2000000, type: 0 };
const send = async (t, l) => {
  for (let i = 0; i < 15; i++) {
    try { const r = await (await t()).wait(); console.log(`  ${l}: ${r.status === 1 ? "ok" : "FAIL"} (block ${r.blockNumber})`); return; }
    catch (e) { if (/r.*31|signature|invalid|underpriced|already known|nonce/i.test(e.message) && i < 14) continue; throw e; }
  }
};
await send(() => h.approve(ZAP, AMT, OVR), "approve HOLLAR->zap");
const zap = new ethers.Contract(ZAP, ["function depositAndSupply(uint256)"], w);
await send(() => zap.depositAndSupply(AMT, OVR), `zap.depositAndSupply(${f(AMT)} HOLLAR)`);
console.log("BIL after: ", f(await abil.balanceOf(me)), " <-- got BIL");
