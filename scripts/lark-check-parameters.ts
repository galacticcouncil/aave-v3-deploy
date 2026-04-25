// Check Hydration's Parameters pallet for IsTestnet flag and fast-governance config.
// Also decode TechnicalCommittee membership.

import { ApiPromise, WsProvider } from "@polkadot/api";
import { decodeAddress, encodeAddress } from "@polkadot/keyring";
import { u8aToHex } from "@polkadot/util";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";

async function main() {
  const provider = new WsProvider(LARK_WS);
  const api = await ApiPromise.create({ provider });

  // Query Parameters pallet - Hydration-specific
  console.log("=== Parameters pallet query methods ===");
  const methods = Object.keys(api.query.parameters || {});
  console.log(methods);

  if (api.query.parameters && api.query.parameters.parameters) {
    try {
      const entries: any = await api.query.parameters.parameters.entries();
      console.log(`\nParameters entries: ${entries.length}`);
      for (const [key, value] of entries) {
        const keyHuman = key.toHuman ? key.toHuman() : key.toString();
        const valHuman = value.toHuman ? value.toHuman() : value.toString();
        console.log(`  ${JSON.stringify(keyHuman)} => ${JSON.stringify(valHuman).slice(0, 300)}`);
      }
    } catch (e) {
      console.log(`parameters error: ${(e as Error).message}`);
    }
  }

  // Check TechnicalCommittee membership
  console.log("\n=== TechnicalCommittee members ===");
  try {
    const members: any = await api.query.technicalCommittee.members();
    for (const m of members) {
      const addr = m.toString();
      const pubkey = u8aToHex(decodeAddress(addr));
      const hydraAddr = encodeAddress(pubkey, 63);
      console.log(`  generic: ${addr}`);
      console.log(`  pubkey:  ${pubkey}`);
      console.log(`  hydra:   ${hydraAddr}`);
    }
  } catch (e) {
    console.log(`error: ${(e as Error).message}`);
  }

  // Check Referenda - maybe there's an ongoing/recent fast referendum we can learn from
  console.log("\n=== Referenda ===");
  try {
    const count: any = await api.query.referenda.referendumCount();
    console.log(`referendumCount: ${count.toString()}`);

    // Check last few
    const cnt = count.toNumber();
    for (let i = Math.max(0, cnt - 5); i < cnt; i++) {
      const ref: any = await api.query.referenda.referendumInfoFor(i);
      if (ref.isSome) {
        const info = ref.unwrap();
        const type = info.type;
        console.log(`  #${i}: ${type}`);
        if (info.isOngoing) {
          const o = info.asOngoing;
          console.log(`    track: ${o.track.toString()}`);
        }
      }
    }
  } catch (e) {
    console.log(`error: ${(e as Error).message}`);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
