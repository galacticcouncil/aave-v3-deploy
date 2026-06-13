// Test trade against the live BIL/HOLLAR stableswap on lark-2.
// Uses Alice (//Alice keypair → her substrate account on Hydration prefix).
// Sells 100 BIL (asset 55, aToken receipt) for HOLLAR (asset 222) via the
// `stableswap.sell` extrinsic; reports the realized rate and slippage vs the
// MMOracle peg (= vault.exchangeRate ≈ 1.0080 today).
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";

const WS = process.env.WS || "wss://2.lark.hydration.cloud";
const POOL_ID = 10055;
const BIL = 55;
const HOLLAR = 222;
const SELL = 100n * 10n ** 18n; // 100 BIL (18 decimals)

const api = await ApiPromise.create({ provider: new WsProvider(WS) });
const keyring = new Keyring({ type: "sr25519" });
const alice = keyring.addFromUri("//Alice");
console.log("trader:", alice.address);

// 1. State before
const balBefore = await api.query.tokens.accounts(alice.address, BIL);
const hollarBefore = await api.query.tokens.accounts(alice.address, HOLLAR);
console.log(`before: ${(balBefore.free.toBigInt() / 10n ** 18n)} BIL, ${(hollarBefore.free.toBigInt() / 10n ** 18n)} HOLLAR`);

// 2. Pool reserves before
const poolReserves = await api.query.stableswap.poolPegs(POOL_ID).catch(() => null);
const reservesData = await api.query.stableswap.pools(POOL_ID);
console.log("pool reserves (raw entry):", reservesData.toHuman());

// 3. Send the swap
// stableswap.sell(poolId, assetIn, assetOut, amountIn, minBuyAmount)
const minBuy = 0; // no slippage protection in this test
const tx = api.tx.stableswap.sell(POOL_ID, BIL, HOLLAR, SELL.toString(), minBuy);
console.log(`\nsubmitting stableswap.sell(${POOL_ID}, ${BIL}, ${HOLLAR}, 100, 0)…`);

const nonce = await api.rpc.system.accountNextIndex(alice.address);
await new Promise((resolve, reject) => {
  let unsub;
  tx.signAndSend(alice, { nonce }, async ({ status, dispatchError, events }) => {
    if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}…`);
    if (!(status.isInBlock || status.isFinalized)) return;
    if (dispatchError) {
      if (dispatchError.isModule) {
        const d = api.registry.findMetaError(dispatchError.asModule);
        unsub?.();
        return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
      }
      unsub?.();
      return reject(new Error(dispatchError.toString()));
    }
    for (const { event } of events) {
      if (event.section === "stableswap" && event.method === "SellExecuted") {
        const data = event.toHuman();
        console.log(`\n→ SellExecuted:`, JSON.stringify(data.data, null, 2));
      }
      if (event.section === "system" && event.method === "ExtrinsicFailed") {
        unsub?.();
        return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
      }
    }
    unsub?.();
    resolve(null);
  }).then((u) => { unsub = u; }).catch(reject);
});

// 4. State after
const balAfter = await api.query.tokens.accounts(alice.address, BIL);
const hollarAfter = await api.query.tokens.accounts(alice.address, HOLLAR);
const bilDelta = (balBefore.free.toBigInt() - balAfter.free.toBigInt());
const hollarDelta = (hollarAfter.free.toBigInt() - hollarBefore.free.toBigInt());
console.log(`\nafter: ${(balAfter.free.toBigInt() / 10n ** 18n)} BIL, ${(hollarAfter.free.toBigInt() / 10n ** 18n)} HOLLAR`);
console.log(`Δ:     -${bilDelta / 10n ** 18n} BIL, +${hollarDelta / 10n ** 18n} HOLLAR`);
// realized rate (HOLLAR per BIL)
const rate = Number(hollarDelta * 10000n / bilDelta) / 10000;
console.log(`realized rate: 1 BIL = ${rate} HOLLAR`);
console.log(`(MMOracle peg ≈ 1.0080 — anything < that is the discount you paid)`);

await api.disconnect();
