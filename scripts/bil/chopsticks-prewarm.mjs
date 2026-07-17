// Pre-warm the chopsticks storage cache with the maps the hydration-ui boot
// query (assetsQuery) enumerates, so the UI's cold-load reads hit the local db
// cache instead of paging every key from the upstream node0.lark. Iterating a
// map via .entries() forces chopsticks to fetch + cache the whole prefix.
import { ApiPromise, WsProvider } from "@polkadot/api";

const api = await ApiPromise.create({
  provider: new WsProvider("ws://localhost:8000"),
  noInitWarn: true,
  throwOnConnect: true,
});

const warm = async (label, fn) => {
  const s = Date.now();
  try {
    const r = await fn();
    const n = Array.isArray(r) ? r.length : "ok";
    console.log(`  ${label}: ${((Date.now() - s) / 1000).toFixed(1)}s (${n})`);
  } catch (e) {
    console.log(`  ${label}: skip (${e.message.slice(0, 50)})`);
  }
};

// The heavy maps the SDK's allPools()/getSupported() + assetsQuery touch.
await warm("assetRegistry.assets", () => api.query.assetRegistry.assets.entries());
await warm("assetRegistry.assetLocations", () => api.query.assetRegistry.assetLocations.entries());
await warm("assetRegistry.assetIds", () => api.query.assetRegistry.assetIds.entries());
await warm("assetRegistry.bannedAssets", () => api.query.assetRegistry.bannedAssets.entries());
await warm("multiTransactionPayment.acceptedCurrencies", () => api.query.multiTransactionPayment.acceptedCurrencies.entries());
await warm("omnipool.assets", () => api.query.omnipool.assets.entries());
await warm("stableswap.pools", () => api.query.stableswap.pools.entries());
await warm("xyk.shareToken", () => api.query.xyk.shareToken.entries());
await warm("xyk.poolAssets", () => api.query.xyk.poolAssets.entries());
await warm("tokens.totalIssuance", () => api.query.tokens.totalIssuance.entries());
await warm("erc20.accountBalances? / evmAccounts.contractDeployer", () => api.query.evmAccounts.contractDeployer.entries());

await api.disconnect();
console.log("prewarm done");
