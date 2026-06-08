#!/usr/bin/env node
// Wire the keeperless Propeller upgrade on lark-2 via ONE Root referendum:
//   SubLoop.setHarvester(NEW_HARVESTER)
//   Vault.setCompoundSlippageBps(100)
//   NEW_HARVESTER.addVault(VAULT)
//   SubLoop.revokeRole(KEEPER_ROLE, OLD_HARVESTER)
//   Vault.revokeRole(KEEPER_ROLE, OLD_HARVESTER)
// All calls dispatch as the GOV aave-manager (holder of ADMIN/DEFAULT_ADMIN).
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";
const SUBLOOP = "0xF23F4baFB4560DFb3234ad7f441Da6260b4218E8";
const VAULT = "0x305EE427b94187c5abC68fCCc194E77D82F39921";
const NEW_HARVESTER = process.env.HARVESTER || process.argv.find((a) => a.startsWith("0x"));
const OLD_HARVESTER = "0x2f766296aEBa33aCCD2a458bD37c998Ffd42e29a";
const SLIPPAGE_BPS = 100;
const KEEPER_ROLE = ethers.utils.id("KEEPER_ROLE");
const HDX = 10n ** 12n;

const subI = new ethers.utils.Interface([
  "function setHarvester(address)",
  "function revokeRole(bytes32,address)",
]);
const vaultI = new ethers.utils.Interface([
  "function setCompoundSlippageBps(uint16)",
  "function revokeRole(bytes32,address)",
]);
const harvI = new ethers.utils.Interface(["function addVault(address)"]);

async function sign(tx, alice, api) {
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((res, rej) => {
    let u;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) {
        const e = dispatchError.isModule
          ? api.registry.findMetaError(dispatchError.asModule)
          : { section: "", name: "" + dispatchError };
        u?.();
        return rej(new Error(`${e.section}.${e.name}`));
      }
      u?.();
      res(events);
    }).then((x) => { u = x; }).catch(rej);
  });
}

async function main() {
  if (!NEW_HARVESTER) throw new Error("pass NEW_HARVESTER addr (arg or HARVESTER env)");
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

  const evm = (target, data) =>
    api.tx.dispatcher.dispatchAsAaveManager(
      api.tx.evm.call(GOV, target, data, "0", "2000000", "100000000", null, null, [], []),
    );

  const inner = [
    evm(SUBLOOP, subI.encodeFunctionData("setHarvester", [NEW_HARVESTER])),
    evm(VAULT, vaultI.encodeFunctionData("setCompoundSlippageBps", [SLIPPAGE_BPS])),
    evm(NEW_HARVESTER, harvI.encodeFunctionData("addVault", [VAULT])),
    evm(SUBLOOP, subI.encodeFunctionData("revokeRole", [KEEPER_ROLE, OLD_HARVESTER])),
    evm(VAULT, vaultI.encodeFunctionData("revokeRole", [KEEPER_ROLE, OLD_HARVESTER])),
  ];
  const batch = api.tx.utility.batchAll(inner);
  const hex = batch.method.toHex(), hash = batch.method.hash.toHex(), len = batch.method.encodedLength;
  console.log(`batch: ${inner.length} calls, ${len} bytes`);
  console.log(`  setHarvester(${NEW_HARVESTER}) · setCompoundSlippageBps(${SLIPPAGE_BPS}) · addVault(${VAULT})`);
  console.log(`  revokeRole(KEEPER, ${OLD_HARVESTER}) on SubLoop + Vault`);
  if (!LIVE) { console.log("DRY-RUN — pass --live to submit the referendum"); await api.disconnect(); return; }

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
  console.log("enacted — verify with cast (harvester, compoundSlippageBps, hasRole)");
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
