import { ApiPromise, WsProvider } from "@polkadot/api";
const api = await ApiPromise.create({ provider: new WsProvider("wss://2.lark.hydration.cloud") });
const POOL_ID = 10055;
const pool = await api.query.stableswap.pools(POOL_ID);
const shareAsset = await api.query.assetRegistry.assets(POOL_ID);
console.log("== pool 10055 ==");
console.log("registered share asset:", shareAsset.isSome ? JSON.stringify(shareAsset.toHuman()) : "(none)");
console.log("pool entry:", pool.isSome ? JSON.stringify(pool.toHuman(), null, 2) : "(none)");
if (pool.isSome) {
  const human = pool.toHuman();
  const assets = human.assets || [];
  for (const aid of assets) {
    const aidNum = Number(aid.toString().replace(/,/g, ""));
    const reserve = await api.query.tokens.accounts(
      (await api.query.assetRegistry.assetLocations(POOL_ID)).isSome ? "" : `0x${(BigInt(POOL_ID) * 0n).toString(16)}`,
      aidNum
    ).catch(() => null);
    const info = await api.query.assetRegistry.assets(aidNum);
    console.log(`  asset ${aidNum}: ${info.isSome ? info.toHuman().symbol : "?"}`);
  }
}
await api.disconnect();
