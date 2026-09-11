// Read-only verification of a Propeller deployment. Sends NO transactions —
// every check is a chain read. Output is a PASS/FAIL table grouped by concern;
// exits non-zero if anything fails.
//
// Run this AFTER the governance wiring referenda have enacted and BEFORE
// announcing the deployment or pointing the UI at it.
//
// Why it matters: `dispatcher.dispatchAsAaveManager` reports EVM reverts as
// `ExecutedFailed` EVENTS rather than failing the extrinsic, so a wiring batch
// can appear to succeed on-chain with individual calls silently reverted. The
// only reliable confirmation is reading the resulting state back — which is
// exactly what this does. (HDCL post-mortem #1: a missed admin transfer bricked
// ref 322 and needed refs 323/324 to recover.)
//
// Usage:
//   WS_URL=wss://rpc.hydradx.cloud RPC_URL=https://rpc.hydradx.cloud \
//   PROPELLER_SYNTH=0x… PROPELLER_SUBLOOP=0x… PROPELLER_HARVESTER=0x… \
//   PROPELLER_VAULTS=0xETH,0xTBTC \
//   npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
//     scripts/propeller/verify-readiness.ts
//
// Optional: PROPELLER_SWAPPER, PROPELLER_GUARDIAN, PROPELLER_LOOPER,
//           PROPELLER_SYNTH_ASSET_ID, POOL.

import { ApiPromise, WsProvider } from "@polkadot/api";
import { ethers } from "ethers";

const WS = process.env.WS_URL || "wss://rpc.hydradx.cloud";
const RPC = process.env.RPC_URL || "https://rpc.hydradx.cloud";

const SYNTH = req("PROPELLER_SYNTH");
const SUBLOOP = req("PROPELLER_SUBLOOP");
const HARVESTER = req("PROPELLER_HARVESTER");
const VAULTS = req("PROPELLER_VAULTS").split(",").map((v) => v.trim()).filter(Boolean);
const SWAPPER = process.env.PROPELLER_SWAPPER;
const GUARDIAN = process.env.PROPELLER_GUARDIAN;
const LOOPER = process.env.PROPELLER_LOOPER;
const SYNTH_ASSET_ID = Number(process.env.PROPELLER_SYNTH_ASSET_ID || 5550);
const POOL = process.env.POOL || "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const GOV = "0xaa7e0000000000000000000000000000000aa7e0";

// The route the loop is pinned to. DcaDispatch bakes ROUTER_PALLET=67 into
// bytecode, so a runtime that renumbers pallets breaks every deploy and unwind
// and can only be fixed by a UUPS upgrade — worth asserting explicitly.
const EXPECT = {
  hollarId: Number(process.env.PROPELLER_HOLLAR_ID || 222),
  primeId: Number(process.env.PROPELLER_PRIME_ID || 43),
  aPrimeId: Number(process.env.PROPELLER_APRIME_ID || 1043),
  poolId: Number(process.env.PROPELLER_PRIME_POOL_ID || 143),
  routerPallet: 67,
  dcaPallet: 66,
  synthLt: 9800,
  synthLtv: 100,
};

function req(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing required env ${name}`);
  return v;
}

type Result = { group: string; name: string; ok: boolean; detail: string };
const results: Result[] = [];
function add(group: string, name: string, ok: boolean, detail = "") {
  results.push({ group, name, ok, detail });
}
const eq = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/// Safe chain read. A verification gate must NEVER abort on the first reverting
/// call — a missing function (wrong contract version) or an unlisted reserve is
/// itself a finding, and the operator needs the whole table to act on. Returns
/// `undefined` on revert so the caller records a FAIL and carries on.
// `any` rather than a generic: these are untyped ethers v5 `Contract` reads, so a
// generic just infers `unknown` and every caller has to cast.
async function sread(fn: () => Promise<any>): Promise<any | undefined> {
  try {
    return await fn();
  } catch {
    return undefined;
  }
}

/// Run a whole section in isolation so one broken subsystem cannot hide the rest.
async function section(group: string, fn: () => Promise<void>) {
  try {
    await fn();
  } catch (e: any) {
    add(group, "section completed", false, `aborted: ${(e.reason || e.message || String(e)).slice(0, 120)}`);
  }
}

const ROLE = (n: string) => ethers.utils.id(n);
const ACCESS_ABI = ["function hasRole(bytes32,address) view returns (bool)"];

async function main() {
  const provider = new ethers.providers.JsonRpcProvider(RPC);

  console.log("Verifying Propeller readiness");
  console.log(`  WS   : ${WS}`);
  console.log(`  RPC  : ${RPC}`);
  console.log(`  synth: ${SYNTH}`);
  console.log(`  loop : ${SUBLOOP}`);
  console.log(`  harv : ${HARVESTER}`);
  console.log(`  vaults: ${VAULTS.join(", ")}\n`);

  const api = await ApiPromise.create({ provider: new WsProvider(WS), noInitWarn: true });

  // ===================================================================
  // A. Runtime — the pallet indices DcaDispatch pins into bytecode
  // ===================================================================
  const ver = await api.rpc.state.getRuntimeVersion();
  add("A. Runtime", "connected", true, `${ver.specName} v${ver.specVersion}`);

  const meta = await api.rpc.state.getMetadata();
  const pallets = (meta.asLatest.pallets as any[]).map((p) => ({
    name: p.name.toString(),
    index: p.index.toNumber(),
  }));
  const router = pallets.find((p) => /^router$/i.test(p.name));
  const dca = pallets.find((p) => /^dca$/i.test(p.name));
  add(
    "A. Runtime",
    `Router pallet index == ${EXPECT.routerPallet} (pinned in DcaDispatch)`,
    !!router && router.index === EXPECT.routerPallet,
    router ? `got ${router.index}` : "pallet not found"
  );
  add(
    "A. Runtime",
    `DCA pallet index == ${EXPECT.dcaPallet} (pinned in DcaDispatch)`,
    !!dca && dca.index === EXPECT.dcaPallet,
    dca ? `got ${dca.index}` : "pallet not found"
  );

  // ===================================================================
  // B. Substrate — the synthetic must be an Erc20 asset pointing at the token
  // ===================================================================
  const synthAsset: any = await api.query.assetRegistry.assets(SYNTH_ASSET_ID);
  add(
    "B. Substrate registry",
    `assets(${SYNTH_ASSET_ID}) exists`,
    synthAsset.isSome,
    synthAsset.isSome ? JSON.stringify(synthAsset.toHuman()) : ""
  );
  if (synthAsset.isSome) {
    const h = synthAsset.toHuman() as any;
    add("B. Substrate registry", "synthetic assetType == Erc20", h?.assetType === "Erc20", `got ${h?.assetType}`);
    add("B. Substrate registry", "synthetic decimals == 18", String(h?.decimals) === "18", `got ${h?.decimals}`);
  }
  try {
    const loc: any = await api.query.assetRegistry.assetLocations(SYNTH_ASSET_ID);
    const key = JSON.stringify(loc.toHuman() ?? {}).toLowerCase();
    add(
      "B. Substrate registry",
      "synthetic location → deployed SyntheticToken",
      key.includes(SYNTH.toLowerCase().replace(/^0x/, "")) || key.includes(SYNTH.toLowerCase()),
      key.slice(0, 120)
    );
  } catch {
    add("B. Substrate registry", "synthetic location readable", false, "assetLocations query failed");
  }

  // ===================================================================
  // C. EVM bytecode present at every Propeller address
  // ===================================================================
  const contracts: Record<string, string> = {
    SyntheticToken: SYNTH,
    SubLoop: SUBLOOP,
    Harvester: HARVESTER,
    Pool: POOL,
  };
  VAULTS.forEach((v, i) => (contracts[`CollateralVault[${i}]`] = v));
  if (SWAPPER) contracts.Swapper = SWAPPER;
  for (const [name, addr] of Object.entries(contracts)) {
    const code = await provider.getCode(addr);
    add("C. EVM bytecode", `${name} has code`, code !== "0x" && code.length > 2, `${addr} (${code.length} chars)`);
  }

  // ===================================================================
  // D. Synthetic reserve config — the vault reads LT LIVE off this
  // ===================================================================
  const pool = new ethers.Contract(
    POOL,
    [
      "function getReservesList() view returns (address[])",
      "function getConfiguration(address) view returns (uint256)",
      "function ADDRESSES_PROVIDER() view returns (address)",
    ],
    provider
  );
  await section("D. Synthetic reserve", async () => {
    const reserves = await sread(() => pool.getReservesList());
    add(
      "D. Synthetic reserve",
      "listed in Pool.getReservesList()",
      !!reserves && reserves.map((r: string) => r.toLowerCase()).includes(SYNTH.toLowerCase()),
      reserves ? `${reserves.length} reserves` : "getReservesList reverted"
    );

    const raw = await sread(() => pool.getConfiguration(SYNTH));
    if (!raw) {
      add("D. Synthetic reserve", "reserve configuration readable", false, "getConfiguration reverted");
      return;
    }
    const cfg = BigInt(raw.toString());
    const ltv = Number(cfg & 0xffffn);
    const lt = Number((cfg >> 16n) & 0xffffn);
    const bonus = Number((cfg >> 32n) & 0xffffn);
    const decimals = Number((cfg >> 48n) & 0xffn);
    const active = ((cfg >> 56n) & 1n) === 1n;
    const frozen = ((cfg >> 57n) & 1n) === 1n;
    const borrowing = ((cfg >> 58n) & 1n) === 1n;

    add("D. Synthetic reserve", `LT == ${EXPECT.synthLt} bps`, lt === EXPECT.synthLt, `got ${lt} — the vault divides by this LIVE`);
    add("D. Synthetic reserve", `LTV == ${EXPECT.synthLtv} bps (must be > 0)`, ltv === EXPECT.synthLtv, `got ${ltv}`);
    add("D. Synthetic reserve", "liquidation bonus > 1e4", bonus > 10000, `got ${bonus}`);
    add("D. Synthetic reserve", "decimals == 18", decimals === 18, `got ${decimals}`);
    add("D. Synthetic reserve", "active", active);
    add("D. Synthetic reserve", "not frozen", !frozen);
    add("D. Synthetic reserve", "borrowing DISABLED", !borrowing, "synth must grant no borrow power");

    const provAddr = await sread(() => pool.ADDRESSES_PROVIDER());
    const oracleAddr = provAddr
      ? await sread(() =>
          new ethers.Contract(provAddr, ["function getPriceOracle() view returns (address)"], provider).getPriceOracle()
        )
      : undefined;
    const price = oracleAddr
      ? await sread(() =>
          new ethers.Contract(oracleAddr, ["function getAssetPrice(address) view returns (uint256)"], provider)
            .getAssetPrice(SYNTH)
        )
      : undefined;
    add(
      "D. Synthetic reserve",
      "oracle prices synthetic at $1",
      !!price && price.toString() === "100000000",
      price ? `got ${price.toString()} (8dp)` : "oracle read reverted"
    );
  });

  // ===================================================================
  // E. Roles
  // ===================================================================
  const synthC = new ethers.Contract(SYNTH, ACCESS_ABI, provider);
  const loopC = new ethers.Contract(
    SUBLOOP,
    [
      ...ACCESS_ABI,
      "function harvester() view returns (address)",
      "function deployTranche() view returns (uint256)",
      "function unwindTranche() view returns (uint256)",
      "function hollarAssetId() view returns (uint32)",
      "function primeAssetId() view returns (uint32)",
      "function aPrimeAssetId() view returns (uint32)",
      "function primePoolId() view returns (uint32)",
      "function dcaSlippagePpm() view returns (uint32)",
      "function targetHf() view returns (uint256)",
      "function deployHfFloor() view returns (uint256)",
      "function deLeverTrigger() view returns (uint256)",
      "function healthFactor() view returns (uint256)",
      "function totalEquity() view returns (uint256)",
      "function principalEquity() view returns (uint256)",
      "function totalShares() view returns (uint256)",
      "function sharesOf(address) view returns (uint256)",
      "function negativeCarryBps() view returns (uint256)",
      "function paused() view returns (bool)",
    ],
    provider
  );

  await section("E. Roles", async () => {
    for (const v of VAULTS) {
      add("E. Roles", `synth MINTER_ROLE -> ${v}`, (await sread(() => synthC.hasRole(ROLE("MINTER_ROLE"), v))) === true);
      add("E. Roles", `subLoop VAULT_ROLE -> ${v}`, (await sread(() => loopC.hasRole(ROLE("VAULT_ROLE"), v))) === true);
    }
    add("E. Roles", "subLoop ADMIN_ROLE -> governance", (await sread(() => loopC.hasRole(ROLE("ADMIN_ROLE"), GOV))) === true);
    add("E. Roles", "subLoop UPGRADER_ROLE -> governance", (await sread(() => loopC.hasRole(ROLE("UPGRADER_ROLE"), GOV))) === true);
    if (GUARDIAN) {
      add(
        "E. Roles",
        "subLoop GUARDIAN_ROLE -> tech committee",
        (await sread(() => loopC.hasRole(ROLE("GUARDIAN_ROLE"), GUARDIAN))) === true,
        GUARDIAN
      );
    }
  });

  // ===================================================================
  // F. Contract wiring — the things that silently fail closed if missed
  // ===================================================================
  const harvC = new ethers.Contract(
    HARVESTER,
    [
      "function vaultCount() view returns (uint256)",
      "function vaults(uint256) view returns (address)",
      "function isRegistered(address) view returns (bool)",
      "function subLoop() view returns (address)",
      "function prime() view returns (address)",
    ],
    provider
  );

  await section("F. Wiring", async () => {
    const wiredHarvester = await sread(() => loopC.harvester());
    add(
      "F. Wiring",
      "subLoop.harvester is set (harvest reverts HarvesterUnset otherwise)",
      eq(wiredHarvester, HARVESTER),
      `got ${wiredHarvester ?? "read reverted"}, expected ${HARVESTER}`
    );

    const dt = await sread(() => loopC.deployTranche());
    const ut = await sread(() => loopC.unwindTranche());
    add("F. Wiring", "subLoop.deployTranche != 0 (0 = unbounded per-poke borrow)", !!dt && !dt.isZero(), dt?.toString() ?? "read reverted");
    add("F. Wiring", "subLoop.unwindTranche != 0", !!ut && !ut.isZero(), ut?.toString() ?? "read reverted");

    const route = {
      hollarId: Number((await sread(() => loopC.hollarAssetId())) ?? -1),
      primeId: Number((await sread(() => loopC.primeAssetId())) ?? -1),
      aPrimeId: Number((await sread(() => loopC.aPrimeAssetId())) ?? -1),
      poolId: Number((await sread(() => loopC.primePoolId())) ?? -1),
    };
    add(
      "F. Wiring",
      `route ids == ${EXPECT.hollarId}/${EXPECT.primeId}/${EXPECT.aPrimeId} via pool ${EXPECT.poolId}`,
      route.hollarId === EXPECT.hollarId &&
        route.primeId === EXPECT.primeId &&
        route.aPrimeId === EXPECT.aPrimeId &&
        route.poolId === EXPECT.poolId,
      JSON.stringify(route)
    );

    const ppmRaw = await sread(() => loopC.dcaSlippagePpm());
    const ppm = Number(ppmRaw ?? 0);
    add("F. Wiring", "dcaSlippagePpm configured (0 = swaps demand exact oracle price)", ppm > 0, `${ppm} ppm = ${(ppm / 10000).toFixed(2)}%`);
    add("F. Wiring", "dcaSlippagePpm <= 10% (sanity bound on a permissionless swap)", ppm > 0 && ppm <= 100000, `${ppm} ppm`);

    add("F. Wiring", "harvester.subLoop == deployed SubLoop", eq(await sread(() => harvC.subLoop()), SUBLOOP));

    const vcRaw = await sread(() => harvC.vaultCount());
    if (vcRaw === undefined) {
      add("F. Wiring", "harvester exposes vaultCount()", false, "reverted — Harvester predates the dedup/removal upgrade");
    } else {
      const vaultCount = Number(vcRaw);
      add("F. Wiring", `harvester registry has ${VAULTS.length} vault(s)`, vaultCount === VAULTS.length, `got ${vaultCount}`);
    }
    for (const v of VAULTS) {
      const reg = await sread(() => harvC.isRegistered(v));
      add("F. Wiring", `harvester registered ${v}`, reg === true, reg === undefined ? "isRegistered() reverted" : "");
    }

    // The completeness check inside Harvester.harvest: every share-holding vault
    // must be registered or the whole shared harvest reverts.
    let registeredShares = ethers.BigNumber.from(0);
    let sharesOk = true;
    for (const v of VAULTS) {
      const s = await sread(() => loopC.sharesOf(v));
      if (s === undefined) sharesOk = false;
      else registeredShares = registeredShares.add(s);
    }
    const totalShares = await sread(() => loopC.totalShares());
    add(
      "F. Wiring",
      "registeredShares == subLoop.totalShares (Harvester.harvest requires this)",
      sharesOk && !!totalShares && registeredShares.eq(totalShares),
      `registered=${registeredShares.toString()} total=${totalShares?.toString() ?? "read reverted"}`
    );
  });

  // ===================================================================
  // G. Per-vault config + live state
  // ===================================================================
  const VAULT_ABI = [
    ...ACCESS_ABI,
    "function synthLtBps() view returns (uint256)",
    "function compoundSlippageBps() view returns (uint16)",
    "function swapper() view returns (address)",
    "function yieldSource() view returns (address)",
    "function synthetic() view returns (address)",
    "function tvlCap() view returns (uint256)",
    "function totalAssets() view returns (uint256)",
    "function totalSupply() view returns (uint256)",
    "function exchangeRate() view returns (uint256)",
    "function loopShares() view returns (uint256)",
    "function syntheticSupplied() view returns (uint256)",
    "function queueHead() view returns (uint256)",
    "function queueTail() view returns (uint256)",
    "function totalQueuedDebt() view returns (uint256)",
    "function paused() view returns (bool)",
    "function depositsPaused() view returns (bool)",
    "function symbol() view returns (string)",
  ];
  for (const v of VAULTS) {
    const c = new ethers.Contract(v, VAULT_ABI, provider);
    const sym = (await sread(() => c.symbol())) ?? v;
    const g = `G. Vault ${sym}`;

    await section(g, async () => {
      add(g, "yieldSource == deployed SubLoop", eq(await sread(() => c.yieldSource()), SUBLOOP));
      add(g, "synthetic == deployed SyntheticToken", eq(await sread(() => c.synthetic()), SYNTH));

      const ltRaw = await sread(() => c.synthLtBps());
      add(
        g,
        `synthLtBps() reads ${EXPECT.synthLt} live`,
        ltRaw !== undefined && Number(ltRaw) === EXPECT.synthLt,
        ltRaw === undefined
          ? "reverts — synthetic reserve not listed yet, every deposit will revert"
          : `got ${Number(ltRaw)}`
      );

      const csbRaw = await sread(() => c.compoundSlippageBps());
      const csb = Number(csbRaw ?? 0);
      add(g, "compoundSlippageBps != 0 (0 => every compound reverts)", csb > 0, `${csb} bps`);
      add(g, "compoundSlippageBps <= 500 (sanity)", csb > 0 && csb <= 500, `${csb} bps`);

      const sw = await sread(() => c.swapper());
      add(
        g,
        "swapper is not the governance placeholder",
        !!sw && !eq(sw, GOV) && sw !== ethers.constants.AddressZero,
        `got ${sw ?? "read reverted"}`
      );
      if (SWAPPER) add(g, "swapper == expected HydraAugustus", eq(sw, SWAPPER), `got ${sw ?? "read reverted"}`);

      add(g, "ADMIN_ROLE -> governance", (await sread(() => c.hasRole(ROLE("ADMIN_ROLE"), GOV))) === true);
      add(g, "UPGRADER_ROLE -> governance", (await sread(() => c.hasRole(ROLE("UPGRADER_ROLE"), GOV))) === true);
      if (GUARDIAN) {
        add(g, "GUARDIAN_ROLE -> tech committee", (await sread(() => c.hasRole(ROLE("GUARDIAN_ROLE"), GUARDIAN))) === true);
      }

      add(g, "not paused", (await sread(() => c.paused())) === false);
      add(g, "deposits not paused", (await sread(() => c.depositsPaused())) === false);
      const cap = await sread(() => c.tvlCap());
      add(g, "tvlCap > 0", !!cap && cap.gt(0), cap?.toString() ?? "read reverted");

      const ta = await sread(() => c.totalAssets());
      const ts = await sread(() => c.totalSupply());
      const qh = await sread(() => c.queueHead());
      const qt = await sread(() => c.queueTail());
      if (ts && ts.gt(0)) {
        const rate = await sread(() => c.exchangeRate());
        add(
          g,
          "exchangeRate >= 1.0 (share price never below par)",
          !!rate && rate.gte(ethers.utils.parseUnits("1", 18)),
          rate?.toString() ?? "read reverted"
        );
      } else {
        add(g, "vault is empty (pre-seed)", true, `totalAssets=${ta?.toString() ?? "?"}`);
      }
      add(
        g,
        "redemption queue not backed up",
        !!qh && !!qt && qt.sub(qh).lte(50),
        `head=${qh?.toString() ?? "?"} tail=${qt?.toString() ?? "?"}`
      );
    });
  }

  // ===================================================================
  // H. Loop health
  // ===================================================================
  await section("H. Loop health", async () => {
    add("H. Loop health", "subLoop not paused", (await sread(() => loopC.paused())) === false);
    const hf = await sread(() => loopC.healthFactor());
    const target = await sread(() => loopC.targetHf());
    const floor = await sread(() => loopC.deployHfFloor());
    const trigger = await sread(() => loopC.deLeverTrigger());
    const wad = (x: any) => (x ? (Number(x.toString()) / 1e18).toFixed(4) : "read reverted");
    const ONE = ethers.utils.parseUnits("1", 18);

    add("H. Loop health", "targetHf > 1.0", !!target && target.gt(ONE), wad(target));
    add("H. Loop health", "deployHfFloor >= targetHf", !!floor && !!target && floor.gte(target), `floor=${wad(floor)} target=${wad(target)}`);
    add("H. Loop health", "deLeverTrigger > targetHf", !!trigger && !!target && trigger.gt(target), `trigger=${wad(trigger)}`);

    const equity = await sread(() => loopC.totalEquity());
    if (equity && equity.gt(0)) {
      // The loop's steady state IS `targetHf` — `pokeBorrow` ramps down to
      // `deployHfFloor` (== targetHf), so a healthy loop sits just above 1.05 and
      // is therefore always below `deLeverTrigger` (1.10). The trigger is a
      // ceiling on when deLever() may be *considered*; the operative condition in
      // `SubLoop.deLever` is `hf < targetHf`. Assert against that, not the trigger.
      add(
        "H. Loop health",
        "live HF >= targetHf (below it, deLever() is armed)",
        !!hf && !!target && hf.gte(target),
        `hf=${wad(hf)} target=${wad(target)} trigger=${wad(trigger)}`
      );
      add(
        "H. Loop health",
        "live HF above Aave's liquidation boundary with margin (>= 1.02)",
        !!hf && hf.gte(ethers.utils.parseUnits("1.02", 18)),
        `hf=${wad(hf)} — below 1.02 the unwind spiral's sell gate never opens`
      );
      const neg = Number((await sread(() => loopC.negativeCarryBps())) ?? -1);
      add("H. Loop health", "no negative carry", neg === 0, `negativeCarryBps=${neg}`);
    } else {
      add(
        "H. Loop health",
        "loop not ramped yet (equity 0)",
        true,
        "pokeBorrow to ramp; requestRedeem reverts NoLoopEquity until then"
      );
    }
  });

  // ===================================================================
  // I. Keeper
  // ===================================================================
  if (LOOPER) {
    await section("I. Keeper", async () => {
      const bal = await sread(() => provider.getBalance(LOOPER));
      add("I. Keeper", "looper has gas", !!bal && bal.gt(ethers.utils.parseUnits("0.1", 18)), bal ? ethers.utils.formatUnits(bal, 18) : "read failed");
      add("I. Keeper", "looper holds NO role (pokes are permissionless)", (await sread(() => loopC.hasRole(ROLE("ADMIN_ROLE"), LOOPER))) === false);
    });
  }

  await api.disconnect();
  // ===================================================================
  // Print
  // ===================================================================
  console.log("");
  let lastGroup = "";
  for (const r of results) {
    if (r.group !== lastGroup) {
      console.log(`\n${"=".repeat(72)}\n  ${r.group}\n${"=".repeat(72)}`);
      lastGroup = r.group;
    }
    console.log(`  ${r.ok ? "✓ PASS" : "✗ FAIL"}  ${r.name}${r.detail ? "\n          " + r.detail : ""}`);
  }
  const passed = results.filter((r) => r.ok).length;
  const failed = results.length - passed;
  console.log(`\n${"=".repeat(72)}`);
  console.log(`  ${passed}/${results.length} checks passed${failed ? `, ${failed} FAILED` : ""}`);
  console.log("=".repeat(72));
  if (failed > 0) {
    console.log("\nFailing checks:");
    for (const r of results.filter((r) => !r.ok)) {
      console.log(`  - [${r.group}] ${r.name}: ${r.detail}`);
    }
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(`\nVERIFY SCRIPT FAILED: ${e.message}`);
  process.exit(2);
});
