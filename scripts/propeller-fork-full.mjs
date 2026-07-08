// Full Propeller fork validation (chopsticks lark2), mirroring the intended
// production structure:
//   1. deploy SyntheticToken from a deployer EOA (admin = governance manager),
//   2. a SINGLE Root proposal registers the Erc20 asset + lists the reserve
//      (initReserves + configure LTV0/LT98 + no-borrow + $1 oracle).
// Proves the listing works against a real contract (error '9' NOT_CONTRACT was
// the placeholder-only blocker). EVM ops use Root-injected dispatchAs (chopsticks
// has no eth RPC and the call-filter blocks direct evm.create/call).
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { compactToU8a, hexToU8a, u8aToHex, u8aConcat } from "@polkadot/util";
import { ethers } from "ethers";
import fs from "fs";

const WS = "ws://127.0.0.1:8011";
const OUT = "/home/mrq/git/aave-v3-deploy/propeller-vault/out";
const ALICE_SS58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY";
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";
const MANAGER = "0xaa7e0000000000000000000000000000000aa7e0";
const CONFIGURATOR = "0x36EdEa6499B14Ddd11455cB2261cDC581211a9f9";
const ORACLE = "0x86c03F1920dE43D3D359487160e1CC1eC44FB319";
const POOL = "0xEAb87D2aAc4C70AF63D2d9E85876665060e117E2";
const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";
const ATOKEN_IMPL = "0x60a9e26Be114e9414190c7bbB028096093b32b31";
const SDEBT_IMPL = "0x849433DA2fAc31d4d4Fd8c7151C2df7BF00fDbEe";
const VDEBT_IMPL = "0x7DF0512B98Ebe481139CcC52B6a54ED8E896CFd8";
const RATE_STRAT = "0x793E7532a11d6b7d5aa892493D758412C3585485";
const TREASURY = "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9";
const INCENTIVES = "0x76D75562bDca79ED5c05975f5A07e77c5Fb5047A";
const SYNTH_ASSET_ID = 5550;

const abi = new ethers.utils.AbiCoder();
const cfgI = new ethers.utils.Interface([
  "function initReserves(tuple(address aTokenImpl,address stableDebtTokenImpl,address variableDebtTokenImpl,uint8 underlyingAssetDecimals,address interestRateStrategyAddress,address underlyingAsset,address treasury,address incentivesController,string aTokenName,string aTokenSymbol,string variableDebtTokenName,string variableDebtTokenSymbol,string stableDebtTokenName,string stableDebtTokenSymbol,bytes params)[] input)",
  "function configureReserveAsCollateral(address,uint256,uint256,uint256)",
  "function setReserveBorrowing(address,bool)",
  "function setSupplyCap(address,uint256)",
]);
const oracleI = new ethers.utils.Interface(["function setAssetSources(address[],address[])"]);
const poolI = new ethers.utils.Interface([
  "function getReserveData(address) view returns (tuple(uint256 data) configuration,uint128 a,uint128 b,uint128 c,uint128 d,uint128 e,uint40 f,uint16 g,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address h,uint128 i,uint128 j,uint128 k)",
]);

function synthInitCode(admin) {
  const j = JSON.parse(fs.readFileSync(`${OUT}/SyntheticToken.sol/SyntheticToken.json`));
  const code = j.bytecode.object.startsWith("0x") ? j.bytecode.object : "0x" + j.bytecode.object;
  const ctor = abi.encode(["string", "string", "address"], ["Propeller Synthetic HOLLAR", "psHOLLAR", admin]);
  return code + ctor.slice(2);
}

async function main() {
  const provider = new WsProvider(WS, 2500, {}, 600000);
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);
  const newBlock = () => send("dev_newBlock", [{ count: 1 }]);

  // Whitelist Alice as a contract deployer.
  const dKey = api.query.evmAccounts.contractDeployer.key(ALICE_EVM);
  await send("dev_setStorage", [[[dKey, "0x"]]]);

  // Enact an inner call as Root via preimage + scheduler injection.
  async function enactRoot(innerCallHex, label) {
    const hash = blake2AsHex(innerCallHex);
    const len = (innerCallHex.length - 2) / 2;
    const body = hexToU8a(innerCallHex);
    const pKey = api.query.preimage.preimageFor.key([hash, len]);
    await send("dev_setStorage", [[[pKey, u8aToHex(u8aConcat(compactToU8a(body.length), body))]]]);
    const statusName = api.query.preimage.requestStatusFor ? "RequestStatusFor" : "StatusFor";
    await send("dev_setStorage", [{ Preimage: { [statusName]: [[[hash], { Requested: { maybeTicket: null, count: 1, maybeLen: len } }]] } }]);
    const head = (await api.rpc.chain.getHeader()).number.toNumber();
    const target = head + 1;
    await send("dev_setStorage", [{ Scheduler: { Agenda: [[[target], [{ maybeId: null, priority: 0, call: { Lookup: { hash_: hash, len } }, maybePeriodic: null, origin: { system: "Root" } }]]] } }]);
    await newBlock();
    const bh = (await api.rpc.chain.getBlockHash(target)).toHex();
    const evs = await (await api.at(bh)).query.system.events();
    console.log(`-- ${label} events @#${target} --`);
    let created = null;
    for (const { event } of evs) {
      const k = `${event.section}.${event.method}`;
      if (k === "evm.Created") created = event.data.toJSON()[0]?.address ?? event.data.toJSON()[0];
      if (/Failed|ExecutedFailed|Unavailable/.test(event.method)) console.log("   FAIL", k, JSON.stringify(event.data.toJSON()));
      if (k === "scheduler.Dispatched") console.log("   scheduler.Dispatched", JSON.stringify(event.data.toJSON()));
    }
    return created;
  }

  const dispatchAs = (signer, call) => api.tx.utility.dispatchAs({ system: { signed: signer } }, call);
  const evmCreate = (code) => api.tx.evm.create(ALICE_EVM, code, "0", "4000000", "2000000000000", null, null, [], []);
  const evmCall = (to, data, gas = "12000000") => api.tx.evm.call(MANAGER, to, data, "0", gas, "2000000000000", null, null, [], []);
  const aaveMgr = (to, data, gas) => api.tx.dispatcher.dispatchAsAaveManager(evmCall(to, data, gas));

  // 1. Deploy SyntheticToken (admin = governance manager) via Root→dispatchAs.
  const deployBatch = api.tx.utility.batchAll([dispatchAs(ALICE_SS58, evmCreate(synthInitCode(MANAGER)))]).method.toHex();
  const synth = await enactRoot(deployBatch, "deploy synth");
  console.log("SYNTH deployed:", synth);
  if (!synth) { console.log("DEPLOY FAILED"); await api.disconnect(); return; }
  const synthCode = await api.query.evm.accountCodes(synth);
  console.log("synth code len:", synthCode.toU8a().length);

  // 2. Single Root proposal: register asset + list reserve + configure + oracle.
  const loc = { parents: 0, interior: { X1: [{ AccountKey20: { network: null, key: synth } }] } };
  const register = api.tx.assetRegistry.register(SYNTH_ASSET_ID, "Propeller Synthetic HOLLAR", "Erc20", "10000000000000000", "psHOLLAR", 18, loc, null, true);
  const input = [{
    aTokenImpl: ATOKEN_IMPL, stableDebtTokenImpl: SDEBT_IMPL, variableDebtTokenImpl: VDEBT_IMPL,
    underlyingAssetDecimals: 18, interestRateStrategyAddress: RATE_STRAT, underlyingAsset: synth,
    treasury: TREASURY, incentivesController: INCENTIVES,
    aTokenName: "Propeller aSynth", aTokenSymbol: "aPSYNTH",
    variableDebtTokenName: "Propeller vDebt Synth", variableDebtTokenSymbol: "vdPSYNTH",
    stableDebtTokenName: "Propeller sDebt Synth", stableDebtTokenSymbol: "sdPSYNTH", params: "0x",
  }];
  const proposal = api.tx.utility.batchAll([
    register,
    aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("initReserves", [input])),
    aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("configureReserveAsCollateral", [synth, 0, 9800, 10100]), "2000000"),
    aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("setReserveBorrowing", [synth, false]), "2000000"),
    aaveMgr(CONFIGURATOR, cfgI.encodeFunctionData("setSupplyCap", [synth, 0]), "2000000"),
    aaveMgr(ORACLE, oracleI.encodeFunctionData("setAssetSources", [[synth], [GHO_ORACLE]]), "2000000"),
  ]).method.toHex();
  await enactRoot(proposal, "list reserve");

  // 3. Verify.
  const res = await api.call.ethereumRuntimeRPCApi.call(ALICE_EVM, POOL, poolI.encodeFunctionData("getReserveData", [synth]), "0", "5000000", null, null, null, false, null, null);
  const rd = res.toJSON()?.ok?.value;
  if (rd && rd !== "0x") {
    const d = poolI.decodeFunctionResult("getReserveData", rd);
    const cfg = BigInt(d.configuration.toString());
    console.log("=== RESULT ===");
    console.log("aToken:", d.aTokenAddress);
    console.log("LTV:", (cfg & 0xffffn).toString(), "LT:", ((cfg >> 16n) & 0xffffn).toString());
    console.log("RESERVE CREATED:", d.aTokenAddress !== ethers.constants.AddressZero);
  } else console.log("getReserveData empty");
  console.log("asset 5550 registered:", (await api.query.assetRegistry.assets(SYNTH_ASSET_ID)).isSome);
  await api.disconnect();
}
main().catch((e) => { console.error("FATAL", e); process.exit(1); });
