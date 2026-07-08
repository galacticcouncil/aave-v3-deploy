// Enact the Propeller proposal on a running chopsticks lark2 fork (Scheduler-Root
// injection, like enact-on-chopsticks) and VERIFY the synthetic reserve was
// actually created (dispatchAsAaveManager swallows EVM reverts as events, so the
// scheduler reporting success is not enough — we read getReserveData via the
// EthereumRuntimeRPCApi runtime call, since chopsticks has no eth RPC).
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { compactToU8a, hexToU8a, u8aToHex, u8aConcat } from "@polkadot/util";
import { ethers } from "ethers";
import fs from "fs";

const WS = process.env.FORK_WS || "ws://127.0.0.1:8011";
const POOL = "0xEAb87D2aAc4C70AF63D2d9E85876665060e117E2";
const ORACLE = "0x86c03F1920dE43D3D359487160e1CC1eC44FB319";
const SYNTH = (process.env.PROPELLER_SYNTH || "0x00000000000000000000000000000000000a5e01").toLowerCase();
const ALICE_EVM = "0xd43593c715fdd31c61141abd04a99fd6822c8558";

async function main() {
  const provider = new WsProvider(WS, 2500, {}, 600000); // 10-min RPC timeout (heavy initReserves block)
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);
  const newBlock = () => send("dev_newBlock", [{ count: 1 }]);
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  const callHex = fs.readFileSync("/tmp/propeller-batch.hex", "utf8").trim();
  const callHash = blake2AsHex(callHex);
  const callLen = (callHex.length - 2) / 2;
  console.log("batch len", callLen, "hash", callHash, "preimage pallet:", !!api.tx.preimage);

  // 1. Inject the preimage directly (notePreimage is call-filtered on lark).
  //    PreimageFor value is BoundedVec<u8> → encode as compact(len) ++ bytes.
  const body = hexToU8a(callHex);
  const preimageForKey = api.query.preimage.preimageFor.key([callHash, callLen]);
  const preimageForVal = u8aToHex(u8aConcat(compactToU8a(body.length), body));
  await send("dev_setStorage", [[[preimageForKey, preimageForVal]]]);
  // status (object form so chopsticks encodes the enum via metadata)
  const statusName = api.query.preimage.requestStatusFor ? "RequestStatusFor" : "StatusFor";
  await send("dev_setStorage", [{
    Preimage: { [statusName]: [[[callHash], { Requested: { maybeTicket: null, count: 1, maybeLen: callLen } }]] },
  }]);
  const rawPre = await send("state_getStorage", [preimageForKey]);
  console.log("preimage present (raw bytes):", rawPre ? (rawPre.length - 2) / 2 : 0);

  // 2. inject Root scheduler agenda at head+1
  const head = (await api.rpc.chain.getHeader()).number.toNumber();
  const target = head + 1;
  await send("dev_setStorage", [{
    Scheduler: { Agenda: [[[target], [{
      maybeId: null, priority: 0,
      call: { Lookup: { hash_: callHash, len: callLen } },
      maybePeriodic: null, origin: { system: "Root" },
    }]]] },
  }]);
  console.log("scheduled Root dispatch at #", target);

  // 3. produce the block that runs it
  await newBlock();

  // 4. events
  const hash = (await api.rpc.chain.getBlockHash(target)).toHex();
  const apiAt = await api.at(hash);
  const events = await apiAt.query.system.events();
  console.log(`=== events in #${target} ===`);
  let dispatched = false;
  for (const { event } of events) {
    const k = `${event.section}.${event.method}`;
    if (k === "scheduler.Dispatched") dispatched = true;
    if (k.startsWith("evm.") || k.startsWith("dispatcher.") || k.startsWith("assetRegistry.") || /Failed|Unavailable|Overweight|ExtrinsicFailed/.test(event.method))
      console.log("  ", k, JSON.stringify(event.data.toJSON()));
  }
  console.log("scheduler.Dispatched:", dispatched);
  const synthAsset0 = await api.query.assetRegistry.assets(5550);
  console.log("substrate asset 5550 registered:", synthAsset0.isSome);

  // 5. VERIFY reserve via EthereumRuntimeRPCApi.call (no eth RPC on chopsticks)
  const ethCallFrom = async (from, to, data, gas = "5000000") => {
    const res = await api.call.ethereumRuntimeRPCApi.call(
      from, to, data, "0", gas, null, null, null, false, null, null
    );
    const j = res.toJSON();
    return j?.ok?.value ?? j?.Ok?.value ?? { err: j?.err ?? j?.Err ?? j };
  };
  const ethCall = (to, data) => ethCallFrom(ALICE_EVM, to, data);

  // 5a. DIAGNOSTIC: replay initReserves from the aave-manager to surface the
  //     revert reason (the on-chain ExecutedFailed swallows it).
  try {
    const CONFIGURATOR = "0x36EdEa6499B14Ddd11455cB2261cDC581211a9f9";
    const MANAGER = "0xaa7e0000000000000000000000000000000aa7e0";
    const initData = fs.readFileSync("/tmp/initreserves.hex", "utf8").trim();
    const r = await ethCallFrom(MANAGER, CONFIGURATOR, initData, "20000000");
    const out = typeof r === "string" ? r : JSON.stringify(r);
    let reason = out;
    if (typeof r === "string" && r.startsWith("0x08c379a0")) {
      reason = ethers.utils.defaultAbiCoder.decode(["string"], "0x" + r.slice(10))[0];
    }
    console.log("initReserves replay result:", out.slice(0, 80), "\n  reason:", reason);
  } catch (e) { console.log("initReserves replay error:", e.message); }
  const iface = new ethers.utils.Interface([
    "function getReserveData(address) view returns (tuple(uint256 data) configuration,uint128 a,uint128 b,uint128 c,uint128 d,uint128 e,uint40 f,uint16 g,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address h,uint128 i,uint128 j,uint128 k)",
    "function getAssetPrice(address) view returns (uint256)",
  ]);
  try {
  const rd = await ethCall(POOL, iface.encodeFunctionData("getReserveData", [SYNTH]));
  console.log("getReserveData raw:", rd ? rd.slice(0, 18) + "…(" + (rd.length / 2) + "B)" : "null");
  if (rd && rd !== "0x") {
    const dec = iface.decodeFunctionResult("getReserveData", rd);
    const cfg = BigInt(dec.configuration.toString());
    const ltv = cfg & 0xffffn;
    const lt = (cfg >> 16n) & 0xffffn;
    console.log("  aToken:", dec.aTokenAddress, "vDebt:", dec.variableDebtTokenAddress);
    console.log("  LTV:", ltv.toString(), "LT:", lt.toString());
    console.log("  RESERVE CREATED:", dec.aTokenAddress !== ethers.constants.AddressZero);
  }
  const pr = await ethCall(ORACLE, iface.encodeFunctionData("getAssetPrice", [SYNTH]));
  if (pr && pr !== "0x") console.log("  price (8dp):", BigInt(pr).toString());
  } catch (e) { console.log("verify ethCall error:", e.message); }

  // 6. VERIFY contract wiring (if the deployed addresses are provided).
  const SUBLOOP = process.env.PROPELLER_SUBLOOP, VAULT = process.env.PROPELLER_VAULT, HARVESTER = process.env.PROPELLER_HARVESTER;
  if (SUBLOOP && VAULT && HARVESTER) {
    try {
      const roleI = new ethers.utils.Interface([
        "function hasRole(bytes32,address) view returns (bool)",
        "function hollarAssetId() view returns (uint32)",
        "function vaults(uint256) view returns (address)",
      ]);
      const MINTER = ethers.utils.id("MINTER_ROLE"), VAULT_ROLE = ethers.utils.id("VAULT_ROLE"), KEEPER = ethers.utils.id("KEEPER_ROLE");
      const hr = async (c, role, acct) => {
        const r = await ethCall(c, roleI.encodeFunctionData("hasRole", [role, acct]));
        return r && BigInt(r) === 1n;
      };
      console.log("=== WIRING ===");
      console.log("  synth MINTER → vault:", await hr(SYNTH, MINTER, VAULT));
      console.log("  subLoop VAULT_ROLE → vault:", await hr(SUBLOOP, VAULT_ROLE, VAULT));
      console.log("  subLoop KEEPER → harvester:", await hr(SUBLOOP, KEEPER, HARVESTER));
      console.log("  vault KEEPER → harvester:", await hr(VAULT, KEEPER, HARVESTER));
      const hid = await ethCall(SUBLOOP, roleI.encodeFunctionData("hollarAssetId", []));
      console.log("  subLoop.hollarAssetId:", hid && hid !== "0x" ? BigInt(hid).toString() : "?");
      const v0 = await ethCall(HARVESTER, roleI.encodeFunctionData("vaults", [0]));
      console.log("  harvester.vaults(0):", v0 && v0 !== "0x" ? "0x" + v0.slice(26) : "?", "(expect", VAULT + ")");
    } catch (e) { console.log("wiring verify error:", e.message); }
  }

  await api.disconnect();
}
main().catch((e) => { console.error("FATAL", e); process.exit(1); });
