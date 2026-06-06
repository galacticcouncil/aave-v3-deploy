import { ApiPromise, WsProvider } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";

const le32 = (x) => Buffer.from([x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >>> 24) & 0xff]);
const le128 = (x) => { let b = Buffer.alloc(16); let v = BigInt(x); for (let i = 0; i < 16; i++) { b[i] = Number(v & 0xffn); v >>= 8n; } return b; };
const compact = (x) => { if (x < 64) return Buffer.from([x << 2]); if (x < 16384) { const v = (x << 2) | 1; return Buffer.from([v & 0xff, (v >> 8) & 0xff]); } const v = (x << 2) | 2; return le32(v); };
const wad = (n) => (10n ** 18n * BigInt(n)).toString();

const OWNER = "0x" + "01".repeat(32);
const order = { Sell: { assetIn: 222, assetOut: 1043, amountIn: wad(100), minAmountOut: 0, route: [{ pool: { Stableswap: 143 }, assetIn: 222, assetOut: 43 }, { pool: "Aave", assetIn: 43, assetOut: 1043 }] } };
const sched = { owner: OWNER, period: 10, totalAmount: wad(2000), maxRetries: null, stabilityThreshold: null, slippage: 10000, order };

// DcaDispatch JS replica
function dcaDispatchBytes() {
  const parts = [];
  parts.push(Buffer.from([66, 0]));           // pallet, call
  parts.push(Buffer.from(OWNER.slice(2), "hex")); // owner 32
  parts.push(le32(10));                       // period
  parts.push(le128(wad(2000)));               // total
  parts.push(Buffer.from([0]));               // max_retries None
  parts.push(Buffer.from([0]));               // stability None
  parts.push(Buffer.from([1])); parts.push(le32(10000)); // slippage Some(ppm)
  parts.push(Buffer.from([0]));               // Order tag Sell=0
  parts.push(le32(222)); parts.push(le32(1043)); // asset_in, asset_out
  parts.push(le128(wad(100)));                // amount_in
  parts.push(le128(0));                       // min_amount_out
  parts.push(compact(2));                     // route len
  // trade0 Stableswap(143) 222->43 : tag 2 + le32(143) + le32(222)+le32(43)
  parts.push(Buffer.from([2])); parts.push(le32(143)); parts.push(le32(222)); parts.push(le32(43));
  // trade1 Aave 43->1043 : tag 4 + le32(43)+le32(1043)
  parts.push(Buffer.from([4])); parts.push(le32(43)); parts.push(le32(1043));
  parts.push(Buffer.from([0]));               // start None
  return "0x" + Buffer.concat(parts).toString("hex");
}

(async () => {
  const api = await ApiPromise.create({ provider: new WsProvider("wss://2.lark.hydration.cloud"), noInitWarn: true });
  const correct = api.tx.dca.schedule(sched, null).method.toHex();
  const mine = dcaDispatchBytes();
  console.log("correct (api.tx):", correct);
  console.log("dcaDispatch     :", mine);
  console.log("MATCH:", correct.toLowerCase() === mine.toLowerCase());
  if (correct.toLowerCase() !== mine.toLowerCase()) {
    const a = correct.slice(2), b = mine.slice(2);
    for (let i = 0; i < Math.max(a.length, b.length); i += 2) {
      if (a.slice(i, i + 2) !== b.slice(i, i + 2)) { console.log(`first diff at byte ${i / 2}: correct=${a.slice(i, i + 2)} mine=${b.slice(i, i + 2)}`); console.log("  correct ctx:", a.slice(Math.max(0, i - 8), i + 16)); console.log("  mine    ctx:", b.slice(Math.max(0, i - 8), i + 16)); break; }
    }
  }
  // also show how PoolType encodes
  console.log("PoolType Aave:", u8aToHex(api.createType("HydradxTraitsRouterPoolType", "Aave").toU8a()));
  console.log("PoolType Stableswap(143):", u8aToHex(api.createType("HydradxTraitsRouterPoolType", { Stableswap: 143 }).toU8a()));
  await api.disconnect();
})().catch((e) => { console.log("err", e.message); process.exit(1); });
