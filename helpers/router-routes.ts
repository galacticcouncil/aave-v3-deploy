// @ts-nocheck
/**
 * Helper for building `router.forceInsertRoute` extrinsics for newly-launched
 * assets that follow the standard "paired with HOLLAR in a 2-asset stablepool"
 * topology (PRIME, EURC, apyUSD, …).
 *
 * Without these on-chain routes the router falls back to its default behaviour
 * (Omnipool only). For new assets that aren't directly in Omnipool, that means
 * fee-payment swaps, AAVE liquidations, and any client using the router won't
 * find a path to/from the new asset → they appear "unswappable" until routes
 * land.
 *
 * Standard reference prefixes (HDX → HOLLAR, WETH → HOLLAR) are hardcoded below.
 * If they change on chain, this file needs an update.
 */

// Canonical reference assets
const HDX = 0;
const WETH = 20;
const HOLLAR = 222;

// HDX → HOLLAR (single-hop via Omnipool — HOLLAR is in Omnipool directly)
const HDX_TO_HOLLAR = [{ pool: "Omnipool", assetIn: HDX, assetOut: HOLLAR }];

// WETH → HOLLAR (5 hops via the GETH stablepool and AAVE wraps)
const WETH_TO_HOLLAR = [
  { pool: { Stableswap: 104 }, assetIn: WETH, assetOut: 1007 },
  { pool: { Stableswap: 4200 }, assetIn: 1007, assetOut: 4200 },
  { pool: "Aave", assetIn: 4200, assetOut: 420 },
  { pool: "Omnipool", assetIn: 420, assetOut: HOLLAR },
];

/**
 * Build the 6 standard `router.forceInsertRoute` calls for an asset paired
 * with HOLLAR in a 2-asset stablepool.
 *
 * @param hydrationTx        polkadot-js `api.tx` for hydradx
 * @param assetId            id of the underlying asset (e.g. apyUSD = 46)
 * @param aTokenId           id of the AAVE aToken wrap (e.g. aapyUSD = 1046)
 * @param sharePoolId        id of the stableswap pool's share asset (e.g. 2-Pool-apyUSD = 146)
 * @returns                  array of 6 `router.forceInsertRoute` extrinsics
 *                           (HDX↔asset, HDX↔aToken, HDX↔share, WETH↔asset, WETH↔aToken, WETH↔share)
 */
export function buildHollarPairedAssetRoutes(
  hydrationTx: any,
  { assetId, aTokenId, sharePoolId }: { assetId: number; aTokenId: number; sharePoolId: number }
) {
  const toAsset = [
    { pool: { Stableswap: sharePoolId }, assetIn: HOLLAR, assetOut: assetId },
  ];
  const toAToken = [
    ...toAsset,
    { pool: "Aave", assetIn: assetId, assetOut: aTokenId },
  ];
  const toShare = [
    { pool: { Stableswap: sharePoolId }, assetIn: HOLLAR, assetOut: sharePoolId },
  ];

  const insert = (assetIn: number, assetOut: number, hops: any[]) =>
    hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, hops);

  return [
    insert(HDX, assetId, [...HDX_TO_HOLLAR, ...toAsset]),
    insert(HDX, aTokenId, [...HDX_TO_HOLLAR, ...toAToken]),
    insert(HDX, sharePoolId, [...HDX_TO_HOLLAR, ...toShare]),
    insert(WETH, assetId, [...WETH_TO_HOLLAR, ...toAsset]),
    insert(WETH, aTokenId, [...WETH_TO_HOLLAR, ...toAToken]),
    insert(WETH, sharePoolId, [...WETH_TO_HOLLAR, ...toShare]),
  ];
}
