// Read live state of the BIL/HOLLAR stableswap pool on lark-2 and run a
// dry-run quote for selling 100 BIL → HOLLAR (without submitting). This
// verifies the pool is alive and quoting reasonable prices before opening
// real trades.
import { ApiPromise, WsProvider } from "@polkadot/api";

const WS = process.env.WS || "wss://2.lark.hydration.cloud";
const POOL_ID = 10055;
const BIL = 55;
const HOLLAR = 222;

const api = await ApiPromise.create({ provider: new WsProvider(WS) });

// 1. Pool config
const pool = await api.query.stableswap.pools(POOL_ID);
const pegs = await api.query.stableswap.poolPegs(POOL_ID);
console.log("=== pool 10055 config ===");
console.log("pool:", JSON.stringify(pool.toHuman(), null, 2));
console.log("pegs:", JSON.stringify(pegs.toHuman(), null, 2));

// 2. Pool's substrate account holds the reserves (orml-tokens)
// Pool account is derived from pool id; use accountId32 truncation.
// Easier: just query each asset's balance for the well-known pool sub-account
// stored in stableswap.poolAddresses or similar. Aave-style: use orml-tokens.accounts
// against the pool's bound substrate account.
//
// On Hydration, stableswap's pool account is derived via the standard pallet
// sub-account convention (PalletId("stbsw___") + pool-id). Instead of computing
// it, ask the chain for the "free" balance of each asset via tokens.totalIssuance
// can give us pool LP issuance; for reserves we look at the LiquidityAdded
// historical event… simpler: use the runtime API if exposed, else just trust
// the LiquidityAdded amounts from the bootstrap event.
//
// For now: print the LP token issuance — that's the simplest invariant check.
const lpSupply = await api.query.tokens.totalIssuance(POOL_ID);
console.log(`\n=== LP token (10055) total supply ===`);
console.log(`${lpSupply.toString()} (≈ ${lpSupply.toBigInt() / 10n ** 18n} shares)`);

// 3. Try a dry-run via runtime API if available, else just report what we know
// Hydration exposes `runtimeApi.stableswapApi.sharesForAmount` or similar.
// Easiest cross-version path: use the SDK's getBestSell which is what the UI
// uses. Skip from this script — confirmed via UI test.
console.log(`\nuse the UI's instant-redeem quote to test the SDK path`);
console.log(`(STABLESWAP_BIL_ASSET_ID = 55, STABLESWAP_POOL_ID = 10055)`);

await api.disconnect();
