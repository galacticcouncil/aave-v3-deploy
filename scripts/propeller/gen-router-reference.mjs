#!/usr/bin/env node
// Regenerate the SCALE reference encodings that `propeller-vault/test/DcaDispatch.t.sol`
// pins `DcaDispatch.encodeRouterSell` against.
//
// WHY THIS EXISTS
// ---------------
// `DcaDispatch` hand-rolls the SCALE encoding for `pallet_route::sell` and bakes the
// pallet index (67) into SubLoop's bytecode as a compile-time constant. A Hydration
// runtime upgrade that reorders `construct_runtime!` silently changes those bytes:
// every deposit and every unwind would start reverting `DispatchFailed`, and because
// the constant lives in a library (inlined into the caller) the ONLY fix is a UUPS
// upgrade of SubLoop.
//
// So: run this after every runtime upgrade, paste the output into DcaDispatch.t.sol,
// and let the test fail loudly if the encoding moved.
//
//   WS=wss://rpc.hydradx.cloud node scripts/propeller/gen-router-reference.mjs
//
// Must be run from the repo root (needs node_modules/@polkadot/api).

import { ApiPromise, WsProvider } from "@polkadot/api";

const WS = process.env.WS || "wss://rpc.hydradx.cloud";

// Mainnet asset ids — override if a lark generation differs.
const HOLLAR = Number(process.env.HOLLAR_ID || 222);
const PRIME = Number(process.env.PRIME_ID || 43);
const APRIME = Number(process.env.APRIME_ID || 1043);
const POOL = Number(process.env.PRIME_POOL_ID || 143);

// Must match DcaDispatch's pinned constants.
const EXPECT_ROUTER_PALLET = 67;
const EXPECT_SELL_CALL = 0;

const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });

const meta = await api.rpc.state.getMetadata();
const pallets = meta.asLatest.pallets.map((p) => ({
  name: p.name.toString(),
  index: p.index.toNumber(),
}));
const router = pallets.find((p) => /^router$/i.test(p.name));
const dca = pallets.find((p) => /^dca$/i.test(p.name));

console.log(`endpoint            : ${WS}`);
console.log(`runtime             : ${(await api.rpc.state.getRuntimeVersion()).specVersion.toString()}`);
console.log(`Router pallet index : ${router?.index}  (DcaDispatch pins ${EXPECT_ROUTER_PALLET})`);
console.log(`DCA pallet index    : ${dca?.index}  (DcaDispatch pins 66, retired path)`);

const [pIdx, cIdx] = api.tx.router.sell.callIndex;
console.log(`router.sell index   : ${pIdx}/${cIdx}  (DcaDispatch pins ${EXPECT_ROUTER_PALLET}/${EXPECT_SELL_CALL})`);

let drift = false;
if (router?.index !== EXPECT_ROUTER_PALLET) {
  console.error(`\n*** DRIFT: Router pallet is ${router?.index}, DcaDispatch has ${EXPECT_ROUTER_PALLET}.`);
  console.error(`    Every deposit and unwind will revert DispatchFailed until SubLoop is upgraded.`);
  drift = true;
}
if (pIdx !== EXPECT_ROUTER_PALLET || cIdx !== EXPECT_SELL_CALL) {
  console.error(`\n*** DRIFT: router.sell call index moved.`);
  drift = true;
}

// Deploy leg — SubLoop._fundDeploy: HOLLAR →[Stableswap]→ PRIME →[Aave]→ aPRIME
const deploy = api.tx.router.sell(HOLLAR, APRIME, "100000000000000000000", "99000000", [
  { pool: { Stableswap: POOL }, assetIn: HOLLAR, assetOut: PRIME },
  { pool: { Aave: null }, assetIn: PRIME, assetOut: APRIME },
]);

// Unwind leg — SubLoop.pokeRepay: aPRIME →[Aave]→ PRIME →[Stableswap]→ HOLLAR
const unwind = api.tx.router.sell(APRIME, HOLLAR, "100000000", "99000000000000000000", [
  { pool: { Aave: null }, assetIn: APRIME, assetOut: PRIME },
  { pool: { Stableswap: POOL }, assetIn: PRIME, assetOut: HOLLAR },
]);

console.log(`
Paste into propeller-vault/test/DcaDispatch.t.sol:

    /// aPRIME(${APRIME}) →[Aave]→ PRIME(${PRIME}) →[Stableswap ${POOL}]→ HOLLAR(${HOLLAR})
    bytes constant UNWIND_REFERENCE =
        hex"${unwind.method.toHex().slice(2)}";

    /// HOLLAR(${HOLLAR}) →[Stableswap ${POOL}]→ PRIME(${PRIME}) →[Aave]→ aPRIME(${APRIME})
    bytes constant DEPLOY_REFERENCE =
        hex"${deploy.method.toHex().slice(2)}";
`);

await api.disconnect();
process.exit(drift ? 1 : 0);
