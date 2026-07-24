// End-to-end BIL deposit (+ withdraw request) on the chopsticks fork.
//  deposit path (what the UI zap does): HOLLAR.approve(zap) -> zap.depositAndSupply -> user holds aBIL (asset 55 aToken)
//  withdraw path: pool.withdraw(uBIL underlying) -> user holds uBIL vault share -> vault.requestRedeem -> queued
import { ApiPromise, WsProvider } from "@polkadot/api";
import { ethers } from "ethers";

const WS = "ws://localhost:8000";
const RPC = "http://localhost:8000";
const PK = process.env.PK ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const VAULT = "0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0";
const POOL = "0x61c36a8d610163660E21a8b7359e1Cac0C9133e1";
const ZAP = "0x4826533B4897376654Bb4d4AD88B7faFD0C98528";
const ABIL = "0x30D8FC13FAb2491347395789e82cCF3F62Aa2e01"; // aToken (asset 55)
const UBIL_UNDERLYING = "0x0000000000000000000000000000000100000226"; // asset 550 (vault share precompile)
const HOLLAR_BAL_SLOT = 3;

const p = new ethers.providers.JsonRpcProvider(RPC);
const w = new ethers.Wallet(PK, p);
const me = w.address;
const fmt = (x) => ethers.utils.formatUnits(x, 18);

// ---- fund HOLLAR (ERC20 slot 3) ----
const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
const ac = new ethers.utils.AbiCoder();
const bkey = ethers.utils.keccak256(ac.encode(["address", "uint256"], [me, HOLLAR_BAL_SLOT]));
const skey = api.query.evm.accountStorages.key(HOLLAR, bkey);
const amt = 50000n * 10n ** 18n;
await api._rpcCore.provider.send("dev_setStorage", [[[skey, "0x" + amt.toString(16).padStart(64, "0")]]]);

const erc20 = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)"];
const hollar = new ethers.Contract(HOLLAR, erc20, w);
const abil = new ethers.Contract(ABIL, erc20, p);
console.log(`user ${me}`);
console.log(`HOLLAR before: ${fmt(await hollar.balanceOf(me))}`);
console.log(`aBIL  before: ${fmt(await abil.balanceOf(me))}`);

const OVR = { gasLimit: 3_000_000, gasPrice: 2_000_000, type: 0 };
async function send(tx, label) {
  for (let i = 0; i < 12; i++) {
    try {
      const r = await (await tx()).wait();
      console.log(`  ${label}: ${r.status === 1 ? "ok" : "FAILED"} (gas ${r.gasUsed})`);
      return r;
    } catch (e) {
      const m = e.message || "";
      if (/r.*31|signature|invalid|underpriced|already known/i.test(m) && i < 11) { continue; }
      throw e;
    }
  }
}

// ---- DEPOSIT via zap ----
const DEP = 10000n * 10n ** 18n;
await send(() => hollar.approve(ZAP, DEP, OVR), "approve HOLLAR->zap");
const zap = new ethers.Contract(ZAP, ["function depositAndSupply(uint256)"], w);
await send(() => zap.depositAndSupply(DEP, OVR), "zap.depositAndSupply(10000 HOLLAR)");

const abilAfter = await abil.balanceOf(me);
console.log(`HOLLAR after deposit: ${fmt(await hollar.balanceOf(me))}`);
console.log(`aBIL  after deposit: ${fmt(abilAfter)}  <-- user now holds BIL (aToken)`);

// ---- WITHDRAW: unwrap aBIL -> uBIL, then requestRedeem ----
const pool = new ethers.Contract(POOL, ["function withdraw(address,uint256,address) returns (uint256)"], w);
const withdrawAmt = abilAfter; // all
await send(() => pool.withdraw(UBIL_UNDERLYING, withdrawAmt, me, OVR), "pool.withdraw(aBIL -> uBIL)");

const ubil = new ethers.Contract(VAULT, [...erc20, "function requestRedeem(uint256,address,address) returns (uint256)", "function pendingRedeemRequest(uint256,address) view returns (uint256)", "function getEstimatedWaitTime(uint256) view returns (uint256)", "function maxRedeem(address) view returns (uint256)"], w);
const ubilBal = await ubil.balanceOf(me);
console.log(`uBIL (vault share) after unwrap: ${fmt(ubilBal)}`);

await send(() => ubil.approve(VAULT, ubilBal, OVR), "approve uBIL->vault (escrow)");
await send(() => ubil.requestRedeem(ubilBal, me, me, OVR), "vault.requestRedeem");

const pending = await ubil.pendingRedeemRequest(0, me);
const maxR = await ubil.maxRedeem(me);
let wait = "n/a";
try { wait = (await ubil.getEstimatedWaitTime(0)).toString(); } catch {}
console.log(`pendingRedeemRequest: ${fmt(pending)} BIL`);
console.log(`maxRedeem (claimable now): ${fmt(maxR)} BIL`);
console.log(`estimated wait (s): ${wait}`);

await api.disconnect();
console.log("\nDONE");
