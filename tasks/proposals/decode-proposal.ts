// @ts-nocheck
import { getApi } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Normalize a field name for cross-representation matching: toHuman() keeps
// runtime field names (snake_case, e.g. `max_peg_update`) while toJSON()
// camelCases them (`maxPegUpdate`).
const normKey = (k: string) => k.toLowerCase().replace(/_/g, "");

// toHuman() renders Perbill/Permill as a 2-decimal percentage, which collapses
// small-but-nonzero values to a misleading "0.00%" (e.g. a Perbill of 200 =
// 0.00002%). Walk the human tree alongside the raw toJSON() tree (same Codec,
// same shape) and annotate every "%"-valued leaf with its raw encoded integer
// so the true on-chain value is always visible: "0.00% (raw 200)".
function annotatePercents(human: any, json: any): any {
  if (
    typeof human === "string" &&
    /%$/.test(human) &&
    (typeof json === "number" || typeof json === "string")
  ) {
    return `${human} (raw ${json})`;
  }
  if (Array.isArray(human)) {
    return human.map((h, i) =>
      annotatePercents(h, Array.isArray(json) ? json[i] : undefined)
    );
  }
  if (human && typeof human === "object") {
    const jmap: { [k: string]: any } = {};
    if (json && typeof json === "object" && !Array.isArray(json)) {
      for (const k of Object.keys(json)) jmap[normKey(k)] = json[k];
    }
    const out: any = {};
    for (const k of Object.keys(human)) {
      out[k] = annotatePercents(human[k], jmap[normKey(k)]);
    }
    return out;
  }
  return human;
}

task(`decode-proposal`, `Decode an encoded proposal and print the decoded tree`)
  .addParam("hex", "The hex-encoded proposal to decode")
  .setAction(async function ({ hex }, hre) {
    const api = await getApi();

    const decoded = api.createType("Call", hex);

    const decoder = new ProposalDecoder(hre);
    await decoder.init();

    const human = annotatePercents(decoded.toHuman(), decoded.toJSON());

    console.log("\n=== Decoded Proposal ===\n");
    decoder.printTree(decoder.transformCall(human));
  });