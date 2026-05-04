// Explore governance pathways on lark 1 to whitelist our EVM deployer.
// Since sudo isn't available, we need to use GeneralAdmin (OpenGov) or similar.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";

async function main() {
  const provider = new WsProvider(LARK_WS);
  const api = await ApiPromise.create({ provider });

  // List all pallets
  console.log("=== Available pallets ===");
  const metadata = await api.rpc.state.getMetadata();
  const pallets = metadata.asLatest.pallets.map((p) => p.name.toString()).sort();
  console.log(pallets.join(", "));

  // Look for governance pallets
  console.log("\n=== Governance-related ===");
  const govPallets = pallets.filter((p) =>
    /sudo|democracy|council|referenda|conviction|whitelist|technical|tech|admin/i.test(p)
  );
  console.log(govPallets);

  // Check for `Parameters` pallet (Hydration often has this for fast-tracking test scenarios)
  const hasParameters = pallets.includes("Parameters");
  console.log(`\nHas Parameters pallet: ${hasParameters}`);

  if (hasParameters) {
    try {
      // Hydration uses Parameters to toggle IsTestnet / governance speed
      // Look for IsTestnet parameter
      const entries = await api.query.parameters.parameters.entries();
      console.log(`Parameters entries: ${entries.length}`);
      for (const [key, value] of entries.slice(0, 20)) {
        console.log(`  ${key.toHuman()} => ${value.toHuman()}`);
      }
    } catch (e) {
      console.log(`query.parameters error: ${(e as Error).message}`);
    }
  }

  // Check TechnicalCommittee membership
  if (pallets.includes("TechnicalCommittee")) {
    try {
      const members: any = await api.query.technicalCommittee.members();
      console.log(`\nTechnicalCommittee members: ${members.toHuman()}`);
    } catch (e) {}
  }
  if (pallets.includes("Council")) {
    try {
      const members: any = await api.query.council.members();
      console.log(`Council members: ${members.toHuman()}`);
    } catch (e) {}
  }

  // Check if there's a "fast referendum" capability on lark
  // Hydration governance often uses Referenda pallet with tracks
  if (pallets.includes("Referenda")) {
    try {
      const tracks = api.consts.referenda.tracks;
      console.log(`\nReferenda tracks: ${JSON.stringify(tracks.toHuman(), null, 2).slice(0, 1000)}`);
    } catch (e) {
      console.log(`consts.referenda.tracks error: ${(e as Error).message}`);
    }
  }

  // Check current block vs FASTEST governance decision period
  const blockNum = await api.rpc.chain.getHeader();
  console.log(`\nCurrent block: ${blockNum.number.toNumber()}`);

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
