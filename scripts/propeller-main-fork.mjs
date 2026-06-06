// Propeller on the lark2 MAIN market, end-to-end on a GC chopsticks fork.
// Deploys SubLoop/Vault/Harvester via Root-injected evm.create (chopsticks has
// no eth_sendRawTransaction; production deploys use forge→chain), reuses the
// already-deployed synth, then a single Root proposal lists the synthetic
// reserve + wires everything. Verifies via the GC fork's eth_call.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { compactToU8a, hexToU8a, u8aToHex, u8aConcat } from "@polkadot/util";
import { ethers } from "ethers";
import fs from "fs";

const WS = "ws://127.0.0.1:8011";
const OUT = "/home/mrq/git/aave-v3-deploy/propeller-vault/out";
const ALICE_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const GOV = "0xAa7e0000000000000000000000000000000Aa7e0";

// lark2 main market
const POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const CONFIGURATOR = "0xE64C38E2Fa00DFe4F1d0B92f75B8E44eBDF292e4";
const ORACLE = "0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760";
// normal (non-GHO) token impls — cloned from ETH's reserve. (HOLLAR's impls are
// GhoAToken/GhoVariableDebtToken, which disable normal supply → OPERATION_NOT_SUPPORTED.)
const ATOKEN_IMPL = "0xc0DF4c545BaFA1788a4Ee55f79704D12fC2c7B5C";
const SDEBT_IMPL = "0xA5b223b3e1f19BfF753E17c72073829010C4d339";
const VDEBT_IMPL = "0xb7e516ba34a85b2Fa554a63407Df8a67f6F49a6C";
const RATE_STRAT = "0x39DfB27D814DB32F904a17560837c9Be8BF1B761";
const TREASURY = "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9";
const INCENTIVES = "0x7472a3D0891Df2401D981A5954d07E364f05060F";
const ETH = "0x0000000000000000000000000000000100000022";
const AETH = "0x11a8f7fFbB7e0fbEd88BC20179Dd45B4Bd6874ff";
const PRIME = "0x000000000000000000000000000000010000002B";
const APRIME = "0x4C892a298A9C6b4cEd988b3D6E9CF93333aADcF7";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const HOLLAR_VDEBT = "0x342923782cCaEBf9c38DD9cb40436e82C42c73B5";
const SYNTH = "0x6E865F78b698085e81298377857f02c00AB0D318";
const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";
const SYNTH_ASSET_ID = 5550;

const abi = new ethers.utils.AbiCoder();
const wad = (x) => ethers.BigNumber.from(10).pow(18).mul(x).toString();

function creation(name, dir = OUT) {
  const path = `${dir}/${name}.sol/${name}.json`;
  const j = JSON.parse(fs.readFileSync(path));
  const c = j.bytecode.object;
  return c.startsWith("0x") ? c : "0x" + c;
}

const subLoopI = new ethers.utils.Interface([
  "function initialize(address,address,address,address,address,address,uint256,uint256,uint256,address)",
  "function registerVault(address)","function setTranches(uint256,uint256)",
  "function configureDca(uint32,uint32,uint32,uint32,uint32,uint32)","function grantRole(bytes32,address)",
  "function hasRole(bytes32,address) view returns (bool)","function hollarAssetId() view returns (uint32)",
  "function pokeBorrow()","function healthFactor() view returns (uint256)","function totalEquity() view returns (uint256)",
]);
const vaultI = new ethers.utils.Interface([
  "function initialize(string,string,address,address,address,address,address,address,address,address,uint16,uint16,uint256,address)",
  "function grantRole(bytes32,address)","function hasRole(bytes32,address) view returns (bool)",
]);
const synthI = new ethers.utils.Interface(["function grantRole(bytes32,address)","function hasRole(bytes32,address) view returns (bool)"]);
const harvI = new ethers.utils.Interface(["function addVault(address)","function vaults(uint256) view returns (address)"]);
const cfgI = new ethers.utils.Interface([
  "function initReserves(tuple(address aTokenImpl,address stableDebtTokenImpl,address variableDebtTokenImpl,uint8 underlyingAssetDecimals,address interestRateStrategyAddress,address underlyingAsset,address treasury,address incentivesController,string aTokenName,string aTokenSymbol,string variableDebtTokenName,string variableDebtTokenSymbol,string stableDebtTokenName,string stableDebtTokenSymbol,bytes params)[])",
  "function configureReserveAsCollateral(address,uint256,uint256,uint256)","function setReserveBorrowing(address,bool)","function setSupplyCap(address,uint256)",
]);
const oracleI = new ethers.utils.Interface(["function setAssetSources(address[],address[])"]);
const poolI = new ethers.utils.Interface(["function getReserveData(address) view returns (tuple(uint256 data) c,uint128 a,uint128 b,uint128 cc,uint128 d,uint128 e,uint40 f,uint16 g,address aTokenAddress,address sd,address vd,address h,uint128 i,uint128 j,uint128 k)"]);

async function main() {
  const provider = new WsProvider(WS, 2500, {}, 600000);
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);
  const newBlock = () => send("dev_newBlock", [{ count: 1 }]);
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  // Read current EVM state (eth_call on the GC fork reads stale base state; the
  // runtime API reads the latest produced block).
  const ethCall = async (to, data) => {
    const res = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, to, data, "0", "5000000", null, null, null, false, null, null);
    return res.toJSON()?.ok?.value ?? "0x";
  };

  // whitelist Alice as deployer
  await send("dev_setStorage", [[[api.query.evmAccounts.contractDeployer.key(ALICE_EVM), "0x"]]]);

  // enact a Root call (preimage injection + scheduler agenda).
  async function enactRoot(innerHex, label, verbose) {
    const hash = blake2AsHex(innerHex), len = (innerHex.length - 2) / 2, body = hexToU8a(innerHex);
    if (verbose) console.log(`  [${label}] preimage ${len} bytes`);
    await send("dev_setStorage", [[[api.query.preimage.preimageFor.key([hash, len]), u8aToHex(u8aConcat(compactToU8a(body.length), body))]]]);
    const sn = api.query.preimage.requestStatusFor ? "RequestStatusFor" : "StatusFor";
    await send("dev_setStorage", [{ Preimage: { [sn]: [[[hash], { Requested: { maybeTicket: null, count: 1, maybeLen: len } }]] } }]);
    const target = (await api.rpc.chain.getHeader()).number.toNumber() + 1;
    await send("dev_setStorage", [{ Scheduler: { Agenda: [[[target], [{ maybeId: null, priority: 0, call: { Lookup: { hash_: hash, len } }, maybePeriodic: null, origin: { system: "Root" } }]]] } }]);
    await newBlock();
    const evs = await (await api.at((await api.rpc.chain.getBlockHash(target)).toHex())).query.system.events();
    let created = null, fails = 0;
    if (verbose) { console.log(`  [${label}] events:`, evs.map((e) => `${e.event.section}.${e.event.method}`).join(" ")); }
    for (const { event } of evs) {
      const k = `${event.section}.${event.method}`;
      if (verbose && (k.startsWith("scheduler.Dispatched") || k.startsWith("evm.") || k.startsWith("dispatcher.") || k.startsWith("utility.") || k.startsWith("dca.") || k.startsWith("system.ExtrinsicFailed"))) {
        let d = event.data.toJSON();
        // decode any module error in the payload
        const ds = JSON.stringify(d);
        if (/"err"|"Err"|module/.test(ds) && /module/.test(ds)) {
          const m = ds.match(/"module":\{"index":(\d+),"error":"(0x[0-9a-f]+)"\}/);
          if (m) { try { const me = api.registry.findMetaError({ index: api.createType("u8", +m[1]), error: api.createType("U32", parseInt(m[2].slice(2,10).match(/../g).reverse().join(""),16)) }); console.log(`    ${k} ERR ${me.section}.${me.name}`); } catch { console.log(`    ${k}`, ds.slice(0, 200)); } }
          else console.log(`    ${k}`, ds.slice(0, 200));
        } else console.log(`    ${k}`, ds.slice(0, 160));
      }
      if (k === "evm.Created") { const d = event.data.toJSON(); created = d[0]?.address ?? d[0]; }
      if (/ExecutedFailed|CallUnavailable|Failed|BatchInterrupted/.test(event.method)) { fails++; if (label) console.log(`  FAIL[${label}]`, k, JSON.stringify(event.data.toJSON())); }
      if (k === "scheduler.Dispatched" && label) {
        const d = event.data.toJSON();
        const res = d.result ?? d[2] ?? d;
        if (JSON.stringify(res).includes("err") || JSON.stringify(res).includes("Err")) {
          fails++;
          const mod = res?.err?.module ?? res?.Err?.Module ?? res?.err?.Module;
          let decoded = "";
          if (mod) { try { const e = api.registry.findMetaError({ index: api.createType("u8", mod.index), error: api.createType("U32", mod.error ?? 0) }); decoded = `${e.section}.${e.name}`; } catch {} }
          console.log(`  DISPATCH-ERR[${label}]`, JSON.stringify(res), decoded);
        }
      }
    }
    return { created, fails };
  }

  const dispatchAs = (call) => api.tx.utility.dispatchAs({ system: { signed: ALICE_SS58 } }, call);
  const evmCreate = (code) => api.tx.evm.create(ALICE_EVM, code, "0", "5000000", "2000000000000", null, null, [], []);
  // gasPrice 6e8 (matches helper); high prices → BalanceLow on the manager acct.
  const evmCall = (from, to, data, gas = "12000000") => api.tx.evm.call(from, to, data, "0", gas, "600000000", null, null, [], []);
  const aaveMgr = (to, data, gas) => api.tx.dispatcher.dispatchAsAaveManager(evmCall(GOV, to, data, gas));

  async function deploy(code, label) {
    const batch = api.tx.utility.batchAll([dispatchAs(evmCreate(code))]).method.toHex();
    const { created, fails } = await enactRoot(batch, label);
    if (!created || fails) throw new Error(`${label} deploy failed (created=${created} fails=${fails})`);
    console.log(`  ${label}:`, created);
    return created;
  }

  console.log("=== deploy stack via Root evm.create ===");
  const subImpl = await deploy(creation("SubLoop"), "SubLoop.impl");
  const subInit = subLoopI.encodeFunctionData("initialize", [POOL, ethers.constants.AddressZero, HOLLAR, PRIME, APRIME, HOLLAR_VDEBT, wad(88).slice(0, -2), wad(105).slice(0, -2), wad(110).slice(0, -2), GOV]);
  const subLoop = await deploy(creation("ERC1967Proxy") + abi.encode(["address", "bytes"], [subImpl, subInit]).slice(2), "SubLoop.proxy");

  const vaultImpl = await deploy(creation("CollateralVault"), "Vault.impl");
  const vaultInit = vaultI.encodeFunctionData("initialize", ["Propeller ETH", "pETH", ETH, POOL, subLoop, GOV, HOLLAR, SYNTH, AETH, HOLLAR_VDEBT, 7400, 9800, wad(1000000), GOV]);
  const vault = await deploy(creation("ERC1967Proxy") + abi.encode(["address", "bytes"], [vaultImpl, vaultInit]).slice(2), "Vault.proxy");

  const harvester = await deploy(creation("Harvester") + abi.encode(["address", "address", "address"], [subLoop, PRIME, GOV]).slice(2), "Harvester");

  console.log("=== list synthetic reserve + wire (single Root batch) ===");
  const loc = { parents: 0, interior: { X1: [{ AccountKey20: { network: null, key: SYNTH } }] } };
  const input = [{
    aTokenImpl: ATOKEN_IMPL, stableDebtTokenImpl: SDEBT_IMPL, variableDebtTokenImpl: VDEBT_IMPL, underlyingAssetDecimals: 18,
    interestRateStrategyAddress: RATE_STRAT, underlyingAsset: SYNTH, treasury: TREASURY, incentivesController: INCENTIVES,
    aTokenName: "Propeller aSynth", aTokenSymbol: "aPSYNTH", variableDebtTokenName: "Propeller vDebt", variableDebtTokenSymbol: "vdPSYNTH",
    stableDebtTokenName: "Propeller sDebt", stableDebtTokenSymbol: "sdPSYNTH", params: "0x",
  }];
  const MINTER = ethers.utils.id("MINTER_ROLE"), KEEPER = ethers.utils.id("KEEPER_ROLE");
  // Split across blocks — one big batchAll is scheduler.PermanentlyOverweight
  // (initReserves alone is ~58e9 refTime + deploys 3 proxies).
  const g = "600000"; // light config/wiring gas
  const batches = {
    "list-reserve": api.tx.utility.batchAll([
      api.tx.assetRegistry.register(SYNTH_ASSET_ID, "Propeller Synthetic HOLLAR", "Erc20", "10000000000000000", "psHOLLAR", 18, loc, null, true),
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("initReserves", [input]), "10000000"),
    ]),
    "configure": api.tx.utility.batchAll([
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("configureReserveAsCollateral", [SYNTH, 0, 9800, 10100]), g),
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("setReserveBorrowing", [SYNTH, false]), g),
      aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("setSupplyCap", [SYNTH, 0]), g),
      aaveMgr(ORACLE, oracleI.encodeFunctionData("setAssetSources", [[SYNTH], [GHO_ORACLE]]), g),
    ]),
    "wire": api.tx.utility.batchAll([
      aaveMgr(SYNTH, synthI.encodeFunctionData("grantRole", [MINTER, vault]), g),
      aaveMgr(subLoop, subLoopI.encodeFunctionData("registerVault", [vault]), g),
      aaveMgr(subLoop, subLoopI.encodeFunctionData("setTranches", [wad(5000), wad(5000)]), g),
      aaveMgr(subLoop, subLoopI.encodeFunctionData("configureDca", [222, 43, 1043, 143, 10, 10000]), g),
      aaveMgr(subLoop, subLoopI.encodeFunctionData("grantRole", [KEEPER, harvester]), g),
      aaveMgr(vault, vaultI.encodeFunctionData("grantRole", [KEEPER, harvester]), g),
      aaveMgr(harvester, harvI.encodeFunctionData("addVault", [vault]), g),
    ]),
  };
  for (const [label, b] of Object.entries(batches)) {
    const r = await enactRoot(b.method.toHex(), label, true);
    console.log(`  ${label} fails:`, r.fails);
  }

  console.log("=== verify (runtime-api eth call) ===");
  try {
    const rd = await ethCall(POOL, poolI.encodeFunctionData("getReserveData", [SYNTH]));
    const d = poolI.decodeFunctionResult("getReserveData", rd);
    const cfg = BigInt(d.c.toString());
    console.log("  synth aToken:", d.aTokenAddress, "LTV", (cfg & 0xffffn).toString(), "LT", ((cfg >> 16n) & 0xffffn).toString());
  } catch (e) { console.log("  getReserveData err:", e.message); }
  try {
    const price = await ethCall(ORACLE, new ethers.utils.Interface(["function getAssetPrice(address) view returns (uint256)"]).encodeFunctionData("getAssetPrice", [SYNTH]));
    console.log("  synth price:", price && price !== "0x" ? BigInt(price).toString() : "(revert)");
  } catch (e) { console.log("  price err:", e.message); }
  const hr = async (c, role, a) => { const r = await ethCall(c, synthI.encodeFunctionData("hasRole", [role, a])); return r && r !== "0x" ? BigInt(r) === 1n : "?"; };
  console.log("  synth MINTER→vault:", await hr(SYNTH, MINTER, vault));
  console.log("  subLoop VAULT_ROLE→vault:", await hr(subLoop, ethers.utils.id("VAULT_ROLE"), vault));
  console.log("  subLoop KEEPER→harvester:", await hr(subLoop, KEEPER, harvester));
  console.log("  vault KEEPER→harvester:", await hr(vault, KEEPER, harvester));
  const hid = await ethCall(subLoop, subLoopI.encodeFunctionData("hollarAssetId", []));
  console.log("  subLoop.hollarAssetId:", hid && hid !== "0x" ? BigInt(hid).toString() : "?");
  console.log("  asset 5550 registered:", (await api.query.assetRegistry.assets(SYNTH_ASSET_ID)).isSome);
  console.log("\nADDRS", JSON.stringify({ subLoop, vault, harvester, synth: SYNTH }));

  // ── SMOKE TEST: deposit ETH → Main position (supply ETH, borrow HOLLAR,
  //    mint+supply synth, seed loop). Drive as Alice via Root→dispatchAs. ──
  console.log("=== smoke: deposit ===");
  const ETH_ASSET = 34;
  // fund Alice with 10 ETH (substrate token → EVM erc20 balance)
  await send("dev_setStorage", [{ Tokens: { Accounts: [[[ALICE_SS58, ETH_ASSET], { free: wad(50), reserved: 0, frozen: 0 }]] } }]);
  const erc20I = new ethers.utils.Interface(["function approve(address,uint256)", "function transfer(address,uint256)", "function balanceOf(address) view returns (uint256)"]);
  const vDepI = new ethers.utils.Interface([
    "function deposit(uint256,address) returns (uint256)", "function balanceOf(address) view returns (uint256)",
    "function totalAssets() view returns (uint256)", "function loopShares() view returns (uint256)", "function syntheticSupplied() view returns (uint256)",
  ]);
  const poolAccI = new ethers.utils.Interface(["function getUserAccountData(address) view returns (uint256 totalCollateralBase,uint256 totalDebtBase,uint256 availableBorrowsBase,uint256 currentLiquidationThreshold,uint256 ltv,uint256 healthFactor)"]);
  const aliceEvmCall = (to, data, gas = "8000000") => api.tx.utility.dispatchAs({ system: { signed: ALICE_SS58 } }, api.tx.evm.call(ALICE_EVM, to, data, "0", gas, "600000000", null, null, [], []));
  const amt = wad(10); // 10 ETH → ~1900 HOLLAR borrowed, above the DCA min budget (~1000)

  // The loop's DCA dispatch (0x0401) runs as the SubLoop's unbound EVM account
  // (ownerOf = addr ++ "ETH\0" ++ 8 zeros). Fund it with native HDX for the
  // schedule ED/fee (it already gets the borrowed HOLLAR budget on deposit).
  const subLoopOwner = "0x45544800" + subLoop.slice(2).toLowerCase() + "0000000000000000"; // "ETH\0"++addr++8x00
  await send("dev_setStorage", [{ System: { Account: [[[subLoopOwner], { providers: 1, sufficients: 1, data: { free: "1000000000000000000", reserved: 0, frozen: 0 } }]] } }]);
  console.log("  funded subLoop DCA owner:", subLoopOwner);

  await enactRoot(api.tx.utility.batchAll([aliceEvmCall(ETH, erc20I.encodeFunctionData("approve", [vault, amt]))]).method.toHex(), "approve", true);

  // simulate deposit first to surface any revert reason (runtime API, current state)
  {
    const res = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, vault, vDepI.encodeFunctionData("deposit", [amt, ALICE_EVM]), "0", "30000000", null, null, null, false, null, null);
    const j = res.toJSON();
    const val = j?.ok?.value ?? "0x";
    const ok = j?.ok?.exitReason?.succeed !== undefined || j?.ok?.exitReason?.Succeed !== undefined;
    let reason = "";
    if (val && val.startsWith && val.startsWith("0x08c379a0")) reason = ethers.utils.defaultAbiCoder.decode(["string"], "0x" + val.slice(10))[0];
    console.log("  deposit SIM exitReason:", JSON.stringify(j?.ok?.exitReason ?? j), "\n    revert full:", typeof val === "string" ? val.slice(0, 260) : val, "\n    reason:", reason);
  }
  await enactRoot(api.tx.utility.batchAll([aliceEvmCall(vault, vDepI.encodeFunctionData("deposit", [amt, ALICE_EVM]), "15000000")]).method.toHex(), "deposit", true);

  try {
    const shares = await ethCall(vault, vDepI.encodeFunctionData("balanceOf", [ALICE_EVM]));
    const ta = await ethCall(vault, vDepI.encodeFunctionData("totalAssets", []));
    const ls = await ethCall(vault, vDepI.encodeFunctionData("loopShares", []));
    const ss = await ethCall(vault, vDepI.encodeFunctionData("syntheticSupplied", []));
    console.log("  vault shares(alice):", BigInt(shares).toString());
    console.log("  vault totalAssets:", BigInt(ta).toString(), "loopShares:", BigInt(ls).toString(), "syntheticSupplied:", BigInt(ss).toString());
    const ud = poolAccI.decodeFunctionResult("getUserAccountData", await ethCall(POOL, poolAccI.encodeFunctionData("getUserAccountData", [vault])));
    console.log("  vault Main: coll(8dp)", ud.totalCollateralBase.toString(), "debt(8dp)", ud.totalDebtBase.toString(), "HF", ud.healthFactor.toString());
  } catch (e) { console.log("  smoke verify err:", e.message); }

  // ── RAMP over blocks: the deploy DCA buys aPRIME over tranches; pokeBorrow
  //    borrows more HOLLAR against the growing aPRIME and refills the DCA, so the
  //    loop levers up toward target HF (1.05). KEEPER drives pokeBorrow.
  console.log("=== ramp over blocks ===");
  await enactRoot(api.tx.utility.batchAll([aaveMgr(subLoop, subLoopI.encodeFunctionData("grantRole", [KEEPER, ALICE_EVM]), "600000")]).method.toHex(), "grant-keeper", false);
  // fund subLoop's DCA owner with extra HDX for repeated schedule fees
  await send("dev_setStorage", [{ System: { Account: [[[subLoopOwner], { providers: 1, sufficients: 1, data: { free: "100000000000000000000", reserved: 0, frozen: 0 } }]] } }]);
  const aprime = async () => BigInt(await ethCall(APRIME, erc20I.encodeFunctionData("balanceOf", [subLoop])));
  const hf = async () => { const r = await ethCall(subLoop, subLoopI.encodeFunctionData("healthFactor", [])); return r && r !== "0x" ? BigInt(r) : -1n; };
  const eq = async () => { const r = await ethCall(subLoop, subLoopI.encodeFunctionData("totalEquity", [])); return r && r !== "0x" ? BigInt(r) : -1n; };
  try {
    for (let i = 0; i < 14; i++) {
      for (let b = 0; b < 11; b++) await newBlock(); // advance past a DCA period
      const r = await enactRoot(api.tx.utility.batchAll([aliceEvmCall(subLoop, subLoopI.encodeFunctionData("pokeBorrow", []), "12000000")]).method.toHex(), `poke${i}`, false);
      console.log(`  ramp ${i}: aPRIME=${(await aprime()).toString()} equity8=${(await eq()).toString()} HF=${(await hf()).toString()} pokeFails=${r.fails}`);
    }
  } catch (e) { console.log("  ramp err:", e.message); }

  await api.disconnect();
}
main().catch((e) => { console.error("FATAL", e); process.exit(1); });
