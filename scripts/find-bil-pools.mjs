// Find any stableswap or XYK pool containing BIL (asset 550) or BIL (asset 55)
// on lark-2 — used to check whether a fast-withdrawal path exists.
import { ApiPromise, WsProvider } from "@polkadot/api";
const api = await ApiPromise.create({ provider: new WsProvider("wss://2.lark.hydration.cloud") });

const ASSET_DCL = 550;
const ASSET_BIL = 55;
const ASSET_HOLLAR = 222; // HOLLAR substrate id on Hydration (=? probably; we know HOLLAR EVM addr but for stableswap need substrate id)

console.log("\n--- all stableswap pools (id → assets) ---");
const entries = await api.query.stableswap.pools.entries();
console.log(`total stableswap pools: ${entries.length}`);
for (const [key, val] of entries) {
  if (!val.isSome) continue;
  const poolId = (key.args[0]).toString();
  const human = val.toHuman();
  const assets = (human.assets || []).map((a) => Number(a.toString().replace(/,/g, "")));
  const flag = (assets.includes(ASSET_DCL) || assets.includes(ASSET_BIL)) ? "  ← BIL/BIL ✓" : "";
  console.log(`pool ${poolId}: assets=${JSON.stringify(assets)}${flag}`);
}

// XYK pools store (AccountId, AccountId) — not asset ids — so we can't filter
// by asset id here. The stableswap scan above is the authoritative answer for
// BIL/BIL pool presence.

await api.disconnect();
