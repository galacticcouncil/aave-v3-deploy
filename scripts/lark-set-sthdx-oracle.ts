// Swap the stHDX price source on GIGAHDX AaveOracle from the EMA-backed
// USDOracleAdapter (which reverts on lark 1) to a FixedPriceOracle.
//
// Flow:
//   1. Read FixedPriceOracle-stHDX-GIGAHDX deployment (must be deployed first).
//   2. Build inner call: evm.call(from=0xaa7e..., to=AaveOracle, setAssetSources([stHDX],[mock]))
//   3. TC-whitelist the inner call hash (Alice is sole TC member on lark 1).
//   4. notePreimage(wrapper).
//   5. Submit whitelisted_caller referendum.
//   6. Alice places decision deposit + votes with 6x conviction full balance.
//   7. On enactment, AaveOracle.getAssetPrice(stHDX) returns the fixed price.
//
// Usage:
//   npx ts-node scripts/lark-set-sthdx-oracle.ts

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const LARK_WS = "wss://2.lark.hydration.cloud";
const LARK_RPC = "https://2.lark.hydration.cloud";

// AaveOracle-GIGAHDX on lark 2 (from Phase 2 deploy)
const AAVE_ORACLE = "0x1f14A240f5Aa8eDD4C5f375B82b3B1d836eF4983";
const STHDX = "0x000000000000000000000000000000010000029e";
const GOV_EVM = "0xaa7e0000000000000000000000000000000aa7e0";
const MAX_VOTE_BASE = 4_000_000_000n * 10n ** 12n; // 4B HDX — Ben's rule

async function signAndWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
          }
          return reject(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
          }
        }
        console.log(`  OK`);
        resolve(events as any[]);
      }
    }).catch(reject);
  });
}

function loadDeployment(name: string): { address: string } {
  const p = path.join(__dirname, "..", "deployments", "hydration", `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`deployment not found: ${p}`);
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

async function main() {
  const mock = loadDeployment("FixedPriceOracle-stHDX-GIGAHDX");
  console.log(`mock oracle: ${mock.address}`);

  // Encode AaveOracle.setAssetSources([stHDX], [mock])
  const iface = new ethers.utils.Interface([
    "function setAssetSources(address[] assets, address[] sources)",
  ]);
  const callData = iface.encodeFunctionData("setAssetSources", [[STHDX], [mock.address]]);
  console.log(`setAssetSources calldata: ${callData}`);

  const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  // Sanity: confirm price is currently reverting + read AaveOracle current source
  const provider = new ethers.providers.JsonRpcProvider(LARK_RPC);
  const aaveOracle = new ethers.Contract(
    AAVE_ORACLE,
    [
      "function getAssetPrice(address) view returns (uint256)",
      "function getSourceOfAsset(address) view returns (address)",
    ],
    provider
  );
  try {
    const src = await aaveOracle.getSourceOfAsset(STHDX);
    console.log(`current stHDX source: ${src}`);
  } catch (e: any) {
    console.log(`getSourceOfAsset err: ${e.message}`);
  }
  try {
    const p = await aaveOracle.getAssetPrice(STHDX);
    console.log(`current stHDX price: ${p.toString()} — already working, aborting`);
    await api.disconnect();
    return;
  } catch {
    console.log("current stHDX price: REVERTS (expected)");
  }

  // Build the inner call: wrap evm.call in dispatcher.dispatchAsAaveManager so
  // pallet-evm's source check accepts the GOV_EVM / AaveManagerAccount identity.
  // Raw evm.call from a whitelist.dispatchWhitelistedCall (Root origin) reverts
  // silently in the EVM because pallet-evm rejects a source it can't verify.
  // Runtime 406 evm.call expects 10 args: (source, target, input, value,
  // gas_limit, max_fee_per_gas, max_priority_fee_per_gas, nonce, access_list,
  // authorization_list). The last one (EIP-7702) was added recently.
  const evmCall: any = (api.tx as any).evm.call(
    GOV_EVM,
    AAVE_ORACLE,
    callData,
    "0",
    1_000_000,
    "1000000000",
    null,
    null,
    [],
    []
  );
  const innerCall: any = (api.tx as any).dispatcher.dispatchAsAaveManager(evmCall);
  const innerHash = innerCall.method.hash.toHex();
  console.log(`inner evm.call hash: ${innerHash}`);

  // TC whitelist
  const wl: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wl.isSome) {
    const wlCall = api.tx.whitelist.whitelistCall(innerHash);
    await signAndWait(
      api.tx.technicalCommittee.propose(1, wlCall, wlCall.method.encodedLength),
      alice,
      api,
      "TC propose(whitelist.whitelistCall)"
    );
  } else {
    console.log("inner already whitelisted");
  }

  // Wrapper (dispatchWhitelistedCallWithPreimage embeds inner inline)
  const wrapper = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
  const wrapperHex = wrapper.method.toHex();
  const wrapperHash = wrapper.method.hash.toHex();
  const wrapperLen = wrapper.method.encodedLength;
  console.log(`wrapper hash: ${wrapperHash} len: ${wrapperLen}`);

  const preReq: any = await api.query.preimage.requestStatusFor(wrapperHash);
  const preOld: any = await api.query.preimage.statusFor(wrapperHash);
  if (!preReq.isSome && !preOld.isSome) {
    await signAndWait(
      api.tx.preimage.notePreimage(wrapperHex),
      alice,
      api,
      "preimage.notePreimage"
    );
  } else {
    console.log("wrapper preimage already noted");
  }

  const events = await signAndWait(
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: wrapperHash, len: wrapperLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit(WhitelistedCaller)"
  );
  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no Submitted event");
  console.log(`ref: ${refIndex}`);

  await signAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api,
    "placeDecisionDeposit"
  );

  const bal: any = await api.query.system.account(alice.address);
  const free = bal.data.free.toBigInt();
  const voteBalance = (free < MAX_VOTE_BASE ? free : MAX_VOTE_BASE).toString();
  console.log(`voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX at 6x (4B cap)`);
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote"
  );

  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!info.isSome) continue;
    const r = info.unwrap();
    console.log(`  [${i}] ${r.type}`);
    if (r.isApproved) break;
    if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled)
      throw new Error(`${r.type}`);
  }

  console.log("waiting 15s for enactment...");
  await new Promise((r) => setTimeout(r, 15000));

  try {
    const src = await aaveOracle.getSourceOfAsset(STHDX);
    console.log(`\nnew stHDX source: ${src}`);
  } catch (e: any) {
    console.log(`getSourceOfAsset err: ${e.message}`);
  }
  try {
    const p = await aaveOracle.getAssetPrice(STHDX);
    console.log(`new stHDX price: ${p.toString()}  (= $${Number(p) / 1e8})`);
    console.log("\nstHDX oracle is now working on lark 1.");
  } catch (e: any) {
    console.log(`\nSTILL REVERTS — check events: ${e.message}`);
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(`FAILED: ${e.message}`);
  process.exit(1);
});
