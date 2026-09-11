#!/usr/bin/env node
// fund + deposit tBTC into the Propeller tBTC vault on real lark2.
//   1. mint tBTC (asset 1000765) to //Alice's substrate acct via one Root ref
//      (her EVM 0xd435.. maps there, so the 0x..0f453d ERC20 precompile sees it)
//   2. approve(tbtcVault, amt) + deposit(amt, alice) signed by Alice (evm.call)
// usage: VAULT_TBTC=0x… node scripts/propeller-deposit-tbtc-lark.mjs [--live]
//
// env: PROPOSAL_WS (ws endpoint), VAULT_TBTC / VAULT (the ptBTC vault — REQUIRED,
//      there is no safe default: the old hardcoded lark-2 address silently sent a
//      deposit at whatever contract now occupies it), MINT / AMT (tBTC, decimals
//      allowed e.g. "0.02").
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const WS = process.env.PROPOSAL_WS || "wss://2.lark.hydration.cloud";
const LIVE = process.argv.includes("--live");
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const ALICE_ACCT = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const TBTC20 = "0x00000000000000000000000000000001000f453d";
const VAULT = process.env.VAULT_TBTC || process.env.VAULT;
if (!VAULT) {
  console.error("set VAULT_TBTC (or VAULT) to the ptBTC vault proxy — no default: lark forks are\n" +
                "re-created and CREATE addresses are deterministic in (deployer, nonce), so a stale\n" +
                "hardcoded address can resolve to an unrelated live contract.");
  process.exit(1);
}
const POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const TBTC_ASSET = 1000765;
// Decimals allowed: BigInt("0.02") throws, so parse via a fixed 1e6 grid then
// scale to 18dp — same trick the ETH deposit/redeem scripts use.
const tbtc = (v, dflt) => (v ? BigInt(Math.round(parseFloat(v) * 1e6)) * 10n ** 12n : dflt * 10n ** 18n);
const MINT = tbtc(process.env.MINT, 2n);
const AMT = tbtc(process.env.AMT, 1n);
const HDX = 10n ** 12n;
// BigInt `/` truncates, so `x / 10n**18n` renders a 0.02 tBTC deposit as "0".
const fmt = (v, dec = 18, places = 8) => (Number(v) / 10 ** dec).toFixed(places);

const erc = new ethers.utils.Interface(["function approve(address,uint256)","function balanceOf(address) view returns (uint256)"]);
const vI = new ethers.utils.Interface([
  "function deposit(uint256,address) returns (uint256)","function balanceOf(address) view returns (uint256)",
  "function totalAssets() view returns (uint256)","function synthLtBps() view returns (uint256)",
  "function tvlCap() view returns (uint256)",
]);
const accI = new ethers.utils.Interface(["function getUserAccountData(address) view returns (uint256 tc,uint256 td,uint256 ab,uint256 lt,uint256 ltv,uint256 hf)"]);

async function sign(tx, alice, api, label) {
  console.log(`\n--- ${label} ---`);
  const nonce = await api.rpc.system.accountNextIndex(alice.address);
  return new Promise((resolve, reject) => {
    let unsub;
    tx.signAndSend(alice, { nonce }, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block ${status.asInBlock.toHex().slice(0, 18)}`);
      if (!(status.isInBlock || status.isFinalized)) return;
      if (dispatchError) { const e = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : { section: "", name: dispatchError.toString() }; unsub?.(); return reject(new Error(`${e.section}.${e.name}`)); }
      for (const { event } of events) { const k = `${event.section}.${event.method}`; if (k === "evm.ExecutedFailed" || k === "evm.Executed") console.log(`  ${k}`, JSON.stringify(event.data.toJSON()).slice(0, 160)); }
      console.log("  OK"); unsub?.(); resolve(events);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider(WS, 2500, {}, 600000), noInitWarn: true });
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  const evmCall = (to, data, gas) => api.tx.evm.call(ALICE_EVM, to, data, "0", gas, "600000000", null, null, [], []);
  const ethCall = async (to, data) => { const r = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "30000000", null, null, null, false, null, null); return r.toJSON(); };

  const balBefore = (await api.query.tokens.accounts(ALICE_ACCT, TBTC_ASSET)).free.toBigInt();
  console.log(`ws=${WS} live=${LIVE}`);
  console.log(`Alice tBTC before: ${fmt(balBefore)} | mint ${fmt(MINT)} | deposit ${fmt(AMT)}`);
  // Read a function that EXISTS. `targetLtvBps()` was removed from CollateralVault;
  // a missing selector returns "0x" here, and BigInt("0x") throws — which aborted
  // this script before it ever reached the deposit.
  const num = (r) => { const v = r?.ok?.value; return v && v !== "0x" ? BigInt(v) : null; };
  const lt = num(await ethCall(VAULT, vI.encodeFunctionData("synthLtBps", [])));
  const cap = num(await ethCall(VAULT, vI.encodeFunctionData("tvlCap", [])));
  console.log(`vault synthLtBps: ${lt ?? "<absent>"}  tvlCap: ${cap === null ? "<absent>" : fmt(cap)} tBTC`);
  if (cap !== null && AMT > cap) throw new Error(`deposit ${fmt(AMT)} exceeds tvlCap ${fmt(cap)}`);

  if (!LIVE) { console.log("\nDRY-RUN"); await api.disconnect(); return; }

  // --- 1. fund tBTC to Alice via Root referendum (currencies.updateBalance) ---
  if (balBefore < AMT) {
    const inner = api.tx.currencies.updateBalance(ALICE_ACCT, TBTC_ASSET, MINT.toString());
    const hex = inner.method.toHex(), hash = inner.method.hash.toHex(), len = inner.method.encodedLength;
    try { await sign(api.tx.preimage.notePreimage(hex), alice, api, "notePreimage"); }
    catch (e) { if (!/AlreadyNoted/i.test(e.message)) throw e; console.log("  already noted"); }
    const ev = await sign(api.tx.referenda.submit({ system: "Root" }, { Lookup: { hash, len } }, { After: 1 }), alice, api, "submit");
    let ref = null; for (const { event } of ev) if (event.section === "referenda" && event.method === "Submitted") ref = event.data[0].toNumber();
    console.log(`  referendum #${ref}`);
    await sign(api.tx.referenda.placeDecisionDeposit(ref), alice, api, "decisionDeposit");
    await sign(api.tx.convictionVoting.vote(ref, { Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: (4_000_000_000n * HDX).toString() } }), alice, api, "vote");
    for (let i = 0; i < 80; i++) {
      await new Promise((r) => setTimeout(r, 3000));
      const info = (await api.query.referenda.referendumInfoFor(ref)).unwrap();
      if (info.isApproved) { console.log(`  [${i}] Approved`); break; }
      if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) throw new Error(`ref ${info.type}`);
    }
    await new Promise((r) => setTimeout(r, 18000));
    const balAfter = (await api.query.tokens.accounts(ALICE_ACCT, TBTC_ASSET)).free.toBigInt();
    console.log(`Alice tBTC after mint: ${fmt(balAfter)}`);
    if (balAfter < AMT) throw new Error("mint did not land");
  } else console.log("Alice already holds enough tBTC; skipping mint");

  // --- 2. approve + deposit ---
  await sign(evmCall(TBTC20, erc.encodeFunctionData("approve", [VAULT, AMT.toString()]), "300000"), alice, api, "approve");
  const sim = await ethCall(VAULT, vI.encodeFunctionData("deposit", [AMT.toString(), ALICE_EVM]));
  const val = sim?.ok?.value ?? "0x"; let reason = "";
  if (typeof val === "string" && val.startsWith("0x08c379a0")) reason = ethers.utils.defaultAbiCoder.decode(["string"], "0x" + val.slice(10))[0];
  console.log("deposit SIM exitReason:", JSON.stringify(sim?.ok?.exitReason ?? sim), reason ? `reason="${reason}"` : "");
  if (reason) throw new Error(`deposit would revert: ${reason}`);

  await sign(evmCall(VAULT, vI.encodeFunctionData("deposit", [AMT.toString(), ALICE_EVM]), "15000000"), alice, api, "deposit");

  // --- 3. verify ---
  const shares = await ethCall(VAULT, vI.encodeFunctionData("balanceOf", [ALICE_EVM]));
  const ta = await ethCall(VAULT, vI.encodeFunctionData("totalAssets", []));
  const ud = accI.decodeFunctionResult("getUserAccountData", (await ethCall(POOL, accI.encodeFunctionData("getUserAccountData", [VAULT]))).ok.value);
  console.log(`\nvault shares(alice): ${BigInt(shares?.ok?.value ?? "0").toString()} (${fmt(BigInt(shares?.ok?.value ?? "0"))})`);
  console.log(`vault totalAssets: ${fmt(BigInt(ta?.ok?.value ?? "0"))} tBTC`);
  console.log(`vault Main: coll8=${ud.tc.toString()} debt8=${ud.td.toString()} HF=${ud.hf.toString()}`);
  await api.disconnect();
}
main().catch((e) => { console.error(e); process.exit(1); });
