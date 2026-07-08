#!/usr/bin/env node
// Wire the new tBTC CollateralVault into the live Propeller deployment via one
// Root referendum (GOV / aave-manager):
//   SubLoop.registerVault(tbtcVault)            — grants VAULT_ROLE (deposit/unwind)
//   Harvester.addVault(tbtcVault)               — pro-rata harvest distribution
//   SyntheticToken.grantRole(MINTER, tbtcVault) — lets the vault mint the HF-floor synth
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const HARVESTER = "0xac19a24ffb72094A830548af6495Da276D2b18be";
const SYNTH = "0x23B69fd91a463ECB4B5864e4C2Ec6a20AFEC47b8";
const TBTC_VAULT = process.env.VAULT || process.argv.find((a) => a.startsWith("0x"));
const MINTER_ROLE = ethers.utils.id("MINTER_ROLE");
const HDX = 10n ** 12n;

const subI = new ethers.utils.Interface(["function registerVault(address)"]);
const harvI = new ethers.utils.Interface(["function addVault(address)"]);
const synthI = new ethers.utils.Interface(["function grantRole(bytes32,address)"]);

async function sign(tx, alice, api) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => {
    let u;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: "" + dispatchError };
        u?.(); return rej(new Error(`${e.section}.${e.name}`));
      }
      u?.(); res(events);
    }).then((x) => { u = x; }).catch(rej);
  });
}

async function main() {
  if (!TBTC_VAULT) throw new Error("pass tBTC vault addr (arg or VAULT env)");
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const evm = (target, data) =>
    api.tx.dispatcher.dispatchAsAaveManager(
      api.tx.evm.call(GOV, target, data, "0", "2000000", "100000000", null, null, [], []),
    );

  const inner = [
    evm(SUBLOOP, subI.encodeFunctionData("registerVault", [TBTC_VAULT])),
    evm(HARVESTER, harvI.encodeFunctionData("addVault", [TBTC_VAULT])),
    evm(SYNTH, synthI.encodeFunctionData("grantRole", [MINTER_ROLE, TBTC_VAULT])),
  ];
  const batch = api.tx.utility.batchAll(inner);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  console.log(`batch: ${inner.length} calls for tBTC vault ${TBTC_VAULT}`);
  console.log(`  registerVault · addVault · grantRole(MINTER)`);
  if (!LIVE) { console.log("DRY-RUN — pass --live"); await api.disconnect(); return; }

  try { await sign(api.tx.preimage.notePreimage(hex), alice, api); } catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; }
  const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api);
  let ref = null;
  for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
  console.log("ref #" + ref);
  await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api);
  await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api);
  for (let i = 0; i < 80; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
    if (info.isApproved) break;
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error("ref " + info.type);
  }
  await new Promise((r) => setTimeout(r, 18000));
  console.log("enacted — verify registerVault/addVault/MINTER");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
