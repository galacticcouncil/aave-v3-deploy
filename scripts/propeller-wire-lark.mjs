#!/usr/bin/env node
// wire the Propeller synthetic reserve + roles on REAL lark2 via Root referenda.
//
// the contracts are already forge-deployed; this lists the synth as an Aave
// reserve and grants the roles. mirrors the 3 batches proven on the chopsticks
// fork (scripts/propeller-main-fork.mjs), but submits each as a real Root-track
// referendum (Alice ~4B HDX confirms in a few blocks) instead of dev_setStorage.
//
// split into 3 referenda because one combined batch is scheduler.PermanentlyOverweight
// (initReserves alone is ~58e9 refTime).
//
// usage:
//   node scripts/propeller-wire-lark.mjs            # dry-run (prints batches)
//   node scripts/propeller-wire-lark.mjs --live     # submit + vote + enact

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");

// deployed on lark2 (forge DeploySynth + DeployMain)
const SYNTH = "0x23B69fd91a463ECB4B5864e4C2Ec6a20AFEC47b8";
const SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const VAULT = "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const HARVESTER = "0x2f766296aEBa33aCCD2a458bD37c998Ffd42e29a";

// lark2 main market (mainnet mirror)
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const CONFIGURATOR = "0xE64C38E2Fa00DFe4F1d0B92f75B8E44eBDF292e4";
const ORACLE = "0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760";
const ATOKEN_IMPL = "0xc0DF4c545BaFA1788a4Ee55f79704D12fC2c7B5C";
const SDEBT_IMPL = "0xA5b223b3e1f19BfF753E17c72073829010C4d339";
const VDEBT_IMPL = "0xb7e516ba34a85b2Fa554a63407Df8a67f6F49a6C";
const RATE_STRAT = "0x39DfB27D814DB32F904a17560837c9Be8BF1B761";
const TREASURY = "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9";
const INCENTIVES = "0x7472a3D0891Df2401D981A5954d07E364f05060F";
const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";
const SYNTH_ASSET_ID = 5550;
const HDX = 10n ** 12n;
const GASPRICE = "100000000"; // 0.1 gwei — ~66x base fee, tiny upfront reservation for GOV

const abi = new ethers.utils.AbiCoder();
const wad = (x) => ethers.BigNumber.from(10).pow(18).mul(x).toString();
const subLoopI = new ethers.utils.Interface([
  "function registerVault(address)", "function setTranches(uint256,uint256)",
  "function configureDca(uint32,uint32,uint32,uint32,uint32)", "function setHarvester(address)",
]);
const vaultI = new ethers.utils.Interface(["function setCompoundSlippageBps(uint16)"]);
const synthI = new ethers.utils.Interface(["function grantRole(bytes32,address)"]);
const harvI = new ethers.utils.Interface(["function addVault(address)"]);
const cfgI = new ethers.utils.Interface([
  "function initReserves(tuple(address aTokenImpl,address stableDebtTokenImpl,address variableDebtTokenImpl,uint8 underlyingAssetDecimals,address interestRateStrategyAddress,address underlyingAsset,address treasury,address incentivesController,string aTokenName,string aTokenSymbol,string variableDebtTokenName,string variableDebtTokenSymbol,string stableDebtTokenName,string stableDebtTokenSymbol,bytes params)[])",
  "function configureReserveAsCollateral(address,uint256,uint256,uint256)", "function setReserveBorrowing(address,bool)", "function setSupplyCap(address,uint256)",
]);
const oracleI = new ethers.utils.Interface(["function setAssetSources(address[],address[])"]);

async function signAndWait(tx, signer, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(signer.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(signer, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() };
        unsub?.(); return reject(new Error(`${e.section}.${e.name}`));
      }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

// submit one batch as a Root referendum, vote it through, wait for enactment,
// and scan the enactment block for the scheduler dispatch result.
async function enactViaReferendum(api, alice, batch, label) {
  const hex = batch.method.toHex();
  const hash = batch.method.hash.toHex();
  const len = batch.method.encodedLength;
  console.log(`\n===== ${label}: hash=${hash} len=${len} =====`);

  try {
    await signAndWait(api.tx.preimage.notePreimage(hex), alice, api, `notePreimage(${label})`);
  } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; console.log("  already noted"); }

  const ev = await signAndWait(
    api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }),
    alice, api, `submit(${label})`
  );
  let ref = null;
  for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  if (ref == null) throw new Error("no refIndex");
  console.log(`  referendum #${ref}`);

  await signAndWait(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "deposit");
  await signAndWait(
    api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }),
    alice, api, "vote"
  );

  let approvedAt = null;
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) { approvedAt = (await api.rpc.chain.getHeader()).number.toNumber(); console.log(`  [${i}] Approved`); break; }
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error(`ref ${info.type}`);
  }
  // wait for enactment + scan the next several blocks for the scheduler dispatch result
  let dispatched = false;
  for (let b = 0; b < 12 && !dispatched; b++) {
    await new Promise((r) => setTimeout(r, 3000));
    const head = (await api.rpc.chain.getHeader()).number.toNumber();
    const apiAt = await api.at(await api.rpc.chain.getBlockHash(head));
    const evs = await apiAt.query.system.events();
    for (const { event } of evs) {
      const k = `${event.section}.${event.method}`;
      if (k === "scheduler.Dispatched") {
        const res = event.data.toJSON();
        const r = res.result ?? res[2] ?? res;
        const failed = JSON.stringify(r).match(/err/i);
        console.log(`  scheduler.Dispatched @${head}:`, failed ? `FAILED ${JSON.stringify(r)}` : "ok");
        dispatched = true;
      }
      if (/ExecutedFailed|BatchInterrupted|ExtrinsicFailed/.test(event.method)) {
        console.log(`  ${k}:`, JSON.stringify(event.data.toJSON()).slice(0, 200));
      }
    }
  }
  if (!dispatched) console.log("  (no scheduler.Dispatched seen in scan window)");
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const evmCall = (to, data, gas) => api.tx.evm.call(GOV, to, data, "0", gas, GASPRICE, null, null, [], []);
  const aaveMgr = (to, data, gas) => api.tx.dispatcher.dispatchAsAaveManager(evmCall(to, data, gas));

  const loc = { parents: 0, interior: { X1: [{ AccountKey20: { network: null, key: SYNTH } }] } };
  const input = [{
    aTokenImpl: ATOKEN_IMPL, stableDebtTokenImpl: SDEBT_IMPL, variableDebtTokenImpl: VDEBT_IMPL, underlyingAssetDecimals: 18,
    interestRateStrategyAddress: RATE_STRAT, underlyingAsset: SYNTH, treasury: TREASURY, incentivesController: INCENTIVES,
    aTokenName: "Propeller aSynth", aTokenSymbol: "aPSYNTH", variableDebtTokenName: "Propeller vDebt", variableDebtTokenSymbol: "vdPSYNTH",
    stableDebtTokenName: "Propeller sDebt", stableDebtTokenSymbol: "sdPSYNTH", params: "0x",
  }];
  const MINTER = ethers.utils.id("MINTER_ROLE");
  const g = "600000";

  const batches = {
    "list-reserve": api.tx.utility.batchAll([
      api.tx.assetRegistry.register(SYNTH_ASSET_ID, "Propeller Synthetic HOLLAR", "Erc20", "10000000000000000", "psHOLLAR", 18, loc, null, true),
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("initReserves", [input]), "10000000"),
    ]),
    "configure": api.tx.utility.batchAll([
      // LTV must be >0 or Aave never enables the synth as collateral (floor inert)
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("configureReserveAsCollateral", [SYNTH, 100, 9800, 10100]), g),
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("setReserveBorrowing", [SYNTH, false]), g),
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("setSupplyCap", [SYNTH, 0]), g),
      aaveMgr(ORACLE, oracleI.encodeFunctionData("setAssetSources", [[SYNTH], [GHO_ORACLE]]), g),
    ]),
    "wire": api.tx.utility.batchAll([
      aaveMgr(SYNTH, synthI.encodeFunctionData("grantRole", [MINTER, VAULT]), g),
      aaveMgr(SUBLOOP, subLoopI.encodeFunctionData("registerVault", [VAULT]), g),
      aaveMgr(SUBLOOP, subLoopI.encodeFunctionData("setTranches", [wad(5000), wad(5000)]), g),
      aaveMgr(SUBLOOP, subLoopI.encodeFunctionData("configureDca", [222, 43, 1043, 143, 10000]), g),
      // keeperless: pin the harvest payout + set compound slippage (no KEEPER grants)
      aaveMgr(SUBLOOP, subLoopI.encodeFunctionData("setHarvester", [HARVESTER]), g),
      aaveMgr(VAULT, vaultI.encodeFunctionData("setCompoundSlippageBps", [100]), g),
      aaveMgr(HARVESTER, harvI.encodeFunctionData("addVault", [VAULT]), g),
    ]),
  };

  console.log(`ws=${WS} live=${LIVE}`);
  for (const [label, b] of Object.entries(batches)) console.log(`  ${label}: len=${b.method.encodedLength}`);

  if (!LIVE) { console.log("\nDRY-RUN — not broadcasting."); await api.disconnect(); return; }

  for (const [label, b] of Object.entries(batches)) {
    await enactViaReferendum(api, alice, b, label);
  }
  console.log("\nall wiring referenda submitted.");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
