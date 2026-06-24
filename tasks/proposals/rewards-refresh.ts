// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import { FORK, POOL_ADMIN } from "../../helpers";
import {
  getEmissionManager,
  getPotRewardsStrategy,
} from "../../helpers/contract-getters";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { ethers, BigNumber } from "ethers";
import { ApiPromise, WsProvider } from "@polkadot/api";

// === gDOT reduction parameters ===
// aToken addresses verified against on-chain PoolDataProvider.getReserveTokensAddresses
const GDOT = "0x0000000000000000000000000000000100000045"; // asset 69
const A_2POOL_GDOT = "0x34D5ffB83D14D82f87aAf2f13BE895a3C814c2ad";
const A_3POOL       = "0xC09CF2f85367f3C2AB66e094283de3a499Cb9108";
const A_2POOL_HUSDT = "0x1806860D27Ee903C1eC7586d4F7D598D7591F124";
const A_2POOL_HUSDC = "0x35774C305aaf441a102D47988d35F0F5428471b3";
const A_2POOL_HUSDS = "0x7E3CE0257506C3E1f96a2a9b25A9440959B0D453";
const A_2POOL_HUSDE = "0x52E1311e26610e6662a1E5B5Bd113130b6815213";
const A_2POOL_HEURC = "0x49f925Bf72718f4AbBC57adeF1b705931f928A2A";

// Stop gDOT emissions on these assets (everything except 2-Pool-GDOT)
const GDOT_ASSETS_TO_STOP = [
  A_3POOL,
  A_2POOL_HUSDT,
  A_2POOL_HUSDC,
  A_2POOL_HUSDS,
  A_2POOL_HUSDE,
  A_2POOL_HEURC,
];

// New 2-Pool-GDOT parameters: 2,350 gDOT per 30 days (18 decimals)
const NEW_GDOT_EPS = "906635802469136";

// Distribution end used by both gDOT reduction AND new PRIME incentives:
// 2026-10-15 14:00:00 UTC
const DISTRIBUTION_END = 1792072800;

// === PRIME incentive parameters ===
const PRIME = "0x000000000000000000000000000000010000002B"; // asset 43
const PRIME_ORACLE = "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307";

// PRIME has 6 decimals. 30-day month = 2,592,000 seconds.
// HUSDT/HUSDC: 8,268.71/month -> floor(8268.71 * 10^6 / 2_592_000) = 3190 raw/sec
// HEURC:       7,295.92/month -> floor(7295.92 * 10^6 / 2_592_000) = 2814 raw/sec
const EPS_PRIME_HUSDT = "3190";
const EPS_PRIME_HUSDC = "3190";
const EPS_PRIME_HEURC = "2814";

// === Aave treasury sweep parameters ===
const AAVE_TREASURY_PROXY = "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9"; // Collector
const TREASURY_CONTROLLER = "0x4Fe896bd708FC32A46Be234d5Ce0Beac59B825F5";
const HYDRATION_TREASURY_EVM = "0x6d6f646c70792f74727372790000000000000000";
const POOL_DATA_PROVIDER = "0xdf18300261edfF47b28c6a6adBCBCf468B52e5a5";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";

task(
  `rewards-refresh`,
  `Combined Economic-Params proposal: reduce gDOT incentives + add PRIME incentives + sweep Aave treasury to native treasury`
).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const provider = hre.ethers.provider;
  const em = await getEmissionManager();
  const transferStrategy = await getPotRewardsStrategy();

  // =========================================================
  // SECTION 1 — reduce / stop gDOT incentives
  // =========================================================
  for (const asset of GDOT_ASSETS_TO_STOP) {
    addTransaction(
      await em.populateTransaction.setEmissionPerSecond(
        asset,
        [GDOT],
        [0],
        { gasLimit: 300000 }
      )
    );
  }

  // Reduce 2-Pool-GDOT to 2,350 gDOT/month
  addTransaction(
    await em.populateTransaction.setEmissionPerSecond(
      A_2POOL_GDOT,
      [GDOT],
      [NEW_GDOT_EPS],
      { gasLimit: 300000 }
    )
  );

  // Push its distributionEnd to the shared 2026-10-15 end
  addTransaction(
    await em.populateTransaction.setDistributionEnd(
      A_2POOL_GDOT,
      GDOT,
      DISTRIBUTION_END,
      { gasLimit: 200000 }
    )
  );

  // =========================================================
  // SECTION 2 — add new PRIME incentives (HUSDT, HUSDC, HEURC)
  // =========================================================
  // Register AaveManager as emission admin for PRIME (first-ever PRIME reward)
  addTransaction(
    await em.populateTransaction.setEmissionAdmin(PRIME, admin, {
      gasLimit: 100000,
    })
  );

  addTransaction(
    await em.populateTransaction.configureAssets(
      [
        {
          emissionPerSecond: EPS_PRIME_HUSDT,
          distributionEnd: DISTRIBUTION_END,
          asset: A_2POOL_HUSDT,
          reward: PRIME,
          transferStrategy: transferStrategy.address,
          rewardOracle: PRIME_ORACLE,
          totalSupply: "0",
        },
        {
          emissionPerSecond: EPS_PRIME_HUSDC,
          distributionEnd: DISTRIBUTION_END,
          asset: A_2POOL_HUSDC,
          reward: PRIME,
          transferStrategy: transferStrategy.address,
          rewardOracle: PRIME_ORACLE,
          totalSupply: "0",
        },
        {
          emissionPerSecond: EPS_PRIME_HEURC,
          distributionEnd: DISTRIBUTION_END,
          asset: A_2POOL_HEURC,
          reward: PRIME,
          transferStrategy: transferStrategy.address,
          rewardOracle: PRIME_ORACLE,
          totalSupply: "0",
        },
      ],
      { gasLimit: 900000 }
    )
  );

  // =========================================================
  // SECTION 3 — sweep Aave treasury -> Hydration treasury (balance - ED each)
  // =========================================================
  const pdpIface = new ethers.utils.Interface([
    "function getAllReservesTokens() view returns (tuple(string symbol, address tokenAddress)[])",
    "function getReserveTokensAddresses(address) view returns (address aToken, address stableDebtToken, address variableDebtToken)",
  ]);
  const reservesRaw = await provider.call({
    to: POOL_DATA_PROVIDER,
    data: pdpIface.encodeFunctionData("getAllReservesTokens"),
  });
  const [reserves] = ethers.utils.defaultAbiCoder.decode(
    ["tuple(string,address)[]"],
    reservesRaw
  );

  const candidates = new Map();
  const add = (label, addr) => {
    const key = addr.toLowerCase();
    if (!candidates.has(key)) candidates.set(key, { label, addr });
  };
  add("HOLLAR", HOLLAR);
  add("GDOT", GDOT);
  for (const r of reserves) {
    const symbol = r[0];
    const underlying = r[1];
    const tokensRaw = await provider.call({
      to: POOL_DATA_PROVIDER,
      data: pdpIface.encodeFunctionData("getReserveTokensAddresses", [underlying]),
    });
    const [aToken] = ethers.utils.defaultAbiCoder.decode(
      ["address", "address", "address"],
      tokensRaw
    );
    add(`${symbol}`, underlying);
    add(`a${symbol}`, aToken);
  }

  // Connect to Substrate to look up asset ID + ED
  console.log("Connecting to Substrate RPC for asset registry lookup...");
  const api = await ApiPromise.create({
    provider: new WsProvider("wss://rpc.hydradx.cloud"),
    noInitWarn: true,
  });

  const assetEntries = await api.query.assetRegistry.assets.entries();
  const byId = new Map();
  for (const [key, data] of assetEntries) {
    byId.set(key.args[0].toNumber(), data.toJSON());
  }

  const locEntries = await api.query.assetRegistry.locationAssets.entries();
  const locToId = new Map();
  for (const [key, data] of locEntries) {
    const loc = key.args[0].toJSON();
    const interior = loc?.interior;
    let evmKey = null;
    if (interior?.x1) {
      const x1 = Array.isArray(interior.x1) ? interior.x1[0] : interior.x1;
      if (x1?.accountKey20) evmKey = x1.accountKey20.key;
    }
    if (evmKey) locToId.set(evmKey.toLowerCase(), data.toJSON());
  }

  const getAssetIdAndED = (addr) => {
    const hex = addr.toLowerCase().replace("0x", "");
    let assetId = null;
    if (hex.startsWith("00000000000000000000000000000001")) {
      assetId = parseInt(hex.slice(32), 16);
    } else {
      const fromLoc = locToId.get(addr.toLowerCase());
      if (fromLoc !== undefined) assetId = fromLoc;
    }
    if (assetId === null) return { assetId: null, ed: null };
    const asset = byId.get(assetId);
    const edRaw = asset?.existentialDeposit;
    let ed;
    if (typeof edRaw === "string" && edRaw.startsWith("0x")) {
      ed = BigNumber.from(edRaw);
    } else if (typeof edRaw === "number") {
      ed = BigNumber.from(edRaw);
    } else {
      ed = BigNumber.from(edRaw || 0);
    }
    return { assetId, ed };
  };

  const erc20 = new ethers.utils.Interface([
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)",
  ]);
  const controllerIface = new ethers.utils.Interface([
    "function transfer(address collector, address token, address recipient, uint256 amount)",
  ]);

  const rows = [];
  for (const [, c] of candidates) {
    try {
      const decRaw = await provider.call({
        to: c.addr,
        data: erc20.encodeFunctionData("decimals"),
      });
      const decimals = BigNumber.from(decRaw).toNumber();
      const balRaw = await provider.call({
        to: c.addr,
        data: erc20.encodeFunctionData("balanceOf", [AAVE_TREASURY_PROXY]),
      });
      const bal = BigNumber.from(balRaw);
      if (bal.isZero()) continue;
      const { assetId, ed } = getAssetIdAndED(c.addr);
      let transferAmount;
      let note = "";
      if (ed === null) {
        transferAmount = bal;
        note = "no-ED (pure ERC20)";
      } else if (bal.lte(ed)) {
        note = `balance <= ED — SKIPPED`;
        rows.push({
          ...c,
          decimals,
          bal,
          ed,
          assetId,
          transferAmount: BigNumber.from(0),
          skip: true,
          note,
        });
        continue;
      } else {
        transferAmount = bal.sub(ed);
        note = `ED reserved: ${ed.toString()}`;
      }
      rows.push({ ...c, decimals, bal, ed, assetId, transferAmount, skip: false, note });
    } catch (e) {}
  }

  await api.disconnect();

  // Dedupe by asset ID (GDOT native precompile vs aGDOT contract share asset 69, etc.)
  const seen = new Map();
  for (const r of rows) {
    if (r.assetId === null) continue;
    const existing = seen.get(r.assetId);
    if (!existing) {
      seen.set(r.assetId, r);
      continue;
    }
    const isNative = (a) =>
      a.toLowerCase().replace("0x", "").startsWith("00000000000000000000000000000001");
    if (isNative(existing.addr) && !isNative(r.addr)) {
      existing.skip = true;
      existing.note = `dupe of asset ${r.assetId} — using ${r.label} instead`;
      seen.set(r.assetId, r);
    } else {
      r.skip = true;
      r.note = `dupe of asset ${r.assetId} — using ${existing.label} instead`;
    }
  }

  console.log(
    `\n=== Sweep: ${rows.filter((r) => !r.skip).length} transfers (${
      rows.filter((r) => r.skip).length
    } skipped) ===`
  );
  for (const r of rows) {
    const balStr = ethers.utils.formatUnits(r.bal, r.decimals);
    const xferStr = r.skip ? "—" : ethers.utils.formatUnits(r.transferAmount, r.decimals);
    console.log(
      `  ${r.label.padEnd(16)} bal=${balStr.padStart(30)}  transfer=${xferStr.padStart(30)}  ${r.note}`
    );
  }

  for (const r of rows) {
    if (r.skip) continue;
    const data = controllerIface.encodeFunctionData("transfer", [
      AAVE_TREASURY_PROXY,
      r.addr,
      HYDRATION_TREASURY_EVM,
      r.transferAmount,
    ]);
    addTransaction({
      to: TREASURY_CONTROLLER,
      data,
      gasLimit: 500000,
      from: "",
    });
  }

  // =========================================================
  // Wrap everything and generate proposal
  // =========================================================
  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  const proposal = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();

  console.log("\n=== Proposal preimage (Economic Parameters) ===\n");
  console.log(proposal.toHex());
  console.log("\n=== Summary ===");
  console.log(`  Total inner calls: ${txs.length}`);
  console.log(`    - gDOT stop calls:        ${GDOT_ASSETS_TO_STOP.length}`);
  console.log(`    - gDOT reduction calls:   2 (setEmissionPerSecond + setDistributionEnd)`);
  console.log(`    - PRIME setup calls:      2 (setEmissionAdmin + configureAssets)`);
  console.log(`    - Treasury sweep transfers: ${rows.filter(r => !r.skip).length}`);
  console.log("\nhash:", proposal.hash.toHex());
});
