#!/usr/bin/env node
// propeller pool-143 rebalancer (HOLLAR 222 <-> PRIME 43, stableswap)
//
// the propeller subloop borrows HOLLAR and DCAs it into PRIME, which slowly
// pushes pool-143 HOLLAR-heavy / PRIME-poor. this keeper watches the reserves
// and swaps to restore the ~1:1 peg:
//   - pool HOLLAR-heavy  -> sell PRIME -> HOLLAR  (spends the pre-funded PRIME stock)
//   - pool PRIME-heavy   -> sell HOLLAR -> PRIME  (needs HOLLAR stock / HSM mint)
//
// the "infinite funds" assumption: the bot account is pre-seeded once with a
// large PRIME balance (lark2 has no sudo, so PRIME can't be minted on the fly).
// HOLLAR is mintable via HSM, so the HOLLAR direction can be topped up; the
// PRIME direction is bounded by the pre-fund.
//
// safety: dry-run by default. live broadcast requires --live AND BOT_SEED set.
//
// env / flags:
//   RPC            ws endpoint        (default wss://2.lark.hydration.cloud)
//   BOT_SEED       mnemonic or //Uri  (required for --live)
//   THRESHOLD      value-share skew that triggers a swap (default 0.02 = 2%)
//   TARGET         value-share to swap back toward          (default 0.5)
//   MAX_PER_CYCLE  cap on amountIn per swap, human units    (default 5000)
//   SLIPPAGE       min-out slippage tolerance               (default 0.01 = 1%)
//   INTERVAL       seconds between cycles in loop mode       (default 60)
//
// usage:
//   node scripts/propeller-rebalancer.mjs --once                 # dry-run, one cycle
//   node scripts/propeller-rebalancer.mjs --once --live          # broadcast one cycle
//   node scripts/propeller-rebalancer.mjs --live                 # persistent loop
//   RPC=ws://127.0.0.1:8011 node ... --once                      # against chopsticks fork

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsU8a } from "@polkadot/util-crypto";
import { u8aToHex } from "@polkadot/util";

const POOL_ID = 143;
const PRIME = 43; // 6 decimals
const HOLLAR = 222; // 18 decimals
const DEC = { [PRIME]: 6, [HOLLAR]: 18 };
const SYM = { [PRIME]: "PRIME", [HOLLAR]: "HOLLAR" };

const args = new Set(process.argv.slice(2));
const ONCE = args.has("--once");
const LIVE = args.has("--live");

const RPC = process.env.RPC || "wss://2.lark.hydration.cloud";
const SEED = process.env.BOT_SEED || "";
const THRESHOLD = Number(process.env.THRESHOLD ?? 0.02);
const TARGET = Number(process.env.TARGET ?? 0.5);
const MAX_PER_CYCLE = Number(process.env.MAX_PER_CYCLE ?? 5000);
const SLIPPAGE = Number(process.env.SLIPPAGE ?? 0.01);
const INTERVAL = Number(process.env.INTERVAL ?? 60) * 1000;

const SCALE = 18n; // common normalization scale
const pow10 = (n) => 10n ** BigInt(n);
const norm = (raw, dec) => (raw * pow10(SCALE - BigInt(dec))); // -> 18dp
const denorm = (val18, dec) => (val18 / pow10(SCALE - BigInt(dec))); // 18dp -> token raw
const human = (raw, dec) => (Number(raw) / Number(pow10(dec))).toLocaleString(undefined, { maximumFractionDigits: 4 });

function poolAccount(poolId) {
  const name = new Uint8Array([...new TextEncoder().encode("sts"), ...new Uint8Array(new Uint32Array([poolId]).buffer)]);
  return u8aToHex(blake2AsU8a(name, 256));
}

async function readReserves(api, acct) {
  const out = {};
  for (const aid of [PRIME, HOLLAR]) {
    const r = await api.query.tokens.accounts(acct, aid);
    out[aid] = r.free.toBigInt();
  }
  return out;
}

// returns { assetIn, assetOut, amountIn } or null if balanced
function planSwap(reserves) {
  const p18 = norm(reserves[PRIME], DEC[PRIME]);
  const h18 = norm(reserves[HOLLAR], DEC[HOLLAR]);
  const total = p18 + h18;
  if (total === 0n) return { skip: "empty pool" };

  const hollarShare = Number(h18) / Number(total);
  const skew = hollarShare - TARGET;

  if (Math.abs(skew) < THRESHOLD) return { balanced: true, hollarShare };

  // move the over-represented side back toward TARGET: swap in the SCARCE asset.
  // target hollar value = TARGET*total; excess = h18 - target. swap ~half the
  // excess so a constant-sum-ish move lands near the midpoint without overshoot.
  const targetH = (total * BigInt(Math.round(TARGET * 1e6))) / 1_000_000n;
  const excess18 = (h18 > targetH ? h18 - targetH : targetH - h18) / 2n;

  let assetIn, assetOut, amountIn18;
  if (skew > 0) {
    // HOLLAR-heavy -> add PRIME / remove HOLLAR -> sell PRIME for HOLLAR
    assetIn = PRIME; assetOut = HOLLAR; amountIn18 = excess18;
  } else {
    // PRIME-heavy -> add HOLLAR / remove PRIME -> sell HOLLAR for PRIME
    assetIn = HOLLAR; assetOut = PRIME; amountIn18 = excess18;
  }

  // cap per-cycle
  const cap18 = pow10(SCALE) * BigInt(Math.round(MAX_PER_CYCLE));
  if (amountIn18 > cap18) amountIn18 = cap18;

  const amountIn = denorm(amountIn18, DEC[assetIn]);
  if (amountIn === 0n) return { balanced: true, hollarShare };
  return { assetIn, assetOut, amountIn, amountIn18, hollarShare, skew };
}

async function cycle(api, signer, acct) {
  const reserves = await readReserves(api, acct);
  const ts = new Date().toISOString();
  console.log(
    `[${ts}] pool-143  PRIME=${human(reserves[PRIME], DEC[PRIME])}  HOLLAR=${human(reserves[HOLLAR], DEC[HOLLAR])}`
  );

  const plan = planSwap(reserves);
  if (plan.skip) { console.log(`  -> skip: ${plan.skip}`); return; }
  if (plan.balanced) { console.log(`  -> balanced (hollar share ${(plan.hollarShare * 100).toFixed(2)}%)`); return; }

  // self-balance guard: the bot can only sell what it holds. when the pool is
  // PRIME-heavy it would need HOLLAR (which it doesn't mint), so it idles until
  // the loop swings the pool HOLLAR-heavy and the PRIME stock is the input.
  // cap before sizing min-out so slippage stays consistent with the real amount.
  if (signer) {
    const own = (await api.query.tokens.accounts(signer.address, plan.assetIn)).free.toBigInt();
    if (own === 0n) { console.log(`  -> skip: bot holds 0 ${SYM[plan.assetIn]}, cannot sell`); return; }
    if (own < plan.amountIn) {
      console.log(`  -> capping to bot ${SYM[plan.assetIn]} balance ${human(own, DEC[plan.assetIn])}`);
      plan.amountIn18 = norm(own, DEC[plan.assetIn]);
      plan.amountIn = own;
    }
  }

  // min out: ~1:1 peg, convert decimals, apply slippage
  const minOut18 = (plan.amountIn18 * BigInt(Math.round((1 - SLIPPAGE) * 1e6))) / 1_000_000n;
  const minBuy = denorm(minOut18, DEC[plan.assetOut]);

  console.log(
    `  -> ${SYM[plan.assetOut]}-heavy  skew=${(plan.skew * 100).toFixed(2)}%  ` +
    `sell ${human(plan.amountIn, DEC[plan.assetIn])} ${SYM[plan.assetIn]} -> ` +
    `>=${human(minBuy, DEC[plan.assetOut])} ${SYM[plan.assetOut]}`
  );

  const tx = api.tx.stableswap.sell(POOL_ID, plan.assetIn, plan.assetOut, plan.amountIn, minBuy);

  if (!LIVE) { console.log(`  -> DRY-RUN (call: ${tx.method.toHex().slice(0, 18)}...), not broadcasting`); return; }

  await new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError }) => {
      if (dispatchError) {
        const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : dispatchError.toString();
        console.log(`  -> FAILED:`, e.section ? `${e.section}.${e.name}` : e);
        return reject(new Error("dispatch error"));
      }
      if (status.isInBlock) { console.log(`  -> in block ${status.asInBlock.toHex().slice(0, 10)}`); resolve(); }
    }).catch(reject);
  });
}

async function main() {
  if (LIVE && !SEED) {
    console.error("--live requires BOT_SEED (mnemonic or //Uri). refusing to broadcast.");
    process.exit(1);
  }
  const api = await ApiPromise.create({ provider: new WsProvider(RPC) });
  const acct = poolAccount(POOL_ID);
  let signer = null;
  if (SEED) {
    const kr = new Keyring({ type: "sr25519" });
    signer = SEED.startsWith("//") ? kr.addFromUri(SEED) : kr.addFromMnemonic(SEED);
    console.log(`bot account: ${signer.address}`);
  }
  console.log(`rpc=${RPC}  pool-acct=${acct}  mode=${LIVE ? "LIVE" : "dry-run"}  threshold=${THRESHOLD}  interval=${INTERVAL / 1000}s`);

  if (ONCE) {
    await cycle(api, signer, acct);
    await api.disconnect();
    return;
  }

  // persistent loop
  const tick = async () => {
    try { await cycle(api, signer, acct); }
    catch (e) { console.error(`  -> cycle error: ${e.message}`); }
  };
  await tick();
  setInterval(tick, INTERVAL);
  // keep alive
}

main().catch((e) => { console.error(e); process.exit(1); });
