// Chopsticks-only helper: write an H160 into the
// `evmAccounts.contractDeployer` whitelist via dev_setStorage. Skips the
// TC + Whitelist pallet dance that whitelist-deployer.ts goes through on
// real chains. Use this on a chopsticks fork when you want to deploy
// contracts without first running the governance flow.
//
// Usage:
//   node scripts/whitelist-deployer-chopsticks.mjs 0x<h160>
import { ApiPromise, WsProvider } from "@polkadot/api";

const h160 = process.argv[2];
if (!h160 || !h160.startsWith("0x")) {
  console.error("usage: whitelist-deployer-chopsticks.mjs 0x<h160>");
  process.exit(2);
}
const WS = process.env.WS_URL ?? "ws://localhost:8000";

const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });
const key = api.query.evmAccounts.contractDeployer.key(h160);
// () = unit value, SCALE-encoded as zero bytes; storage presence is what matters
await api._rpcCore.provider.send("dev_setStorage", [[[key, "0x"]]]);

const after = await api.query.evmAccounts.contractDeployer(h160);
console.log(`evmAccounts.contractDeployer[${h160}] = ${after.toHuman()}`);
await api.disconnect();
