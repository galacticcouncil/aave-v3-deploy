// @ts-nocheck
import {
  location,
  generateProposalV2,
  getApi,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  FORK,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  EMERGENCY_ADMIN,
  TREASURY_PROXY_ID,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Fixed $1 oracle (reused for the synthetic — it is pegged $1 by design, like HOLLAR).
const GHO_ORACLE_ADDRESS = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";

// ── Propeller synthetic collateral ─────────────────────────────────────────
//   - reserve: LTV 1% / LT 98% / borrowing disabled / non-isolation / $1 oracle
//     → supplied by each CollateralVault to floor its Main position's HF so the
//       principal is un-liquidatable at any collateral price.
//   - LTV must be a SMALL NON-ZERO value: Aave refuses to enable an LTV-0 reserve
//     as collateral (validateUseAsCollateral), which leaves the synth out of
//     totalCollateralBase — HF floor inert + rebalance broken (found live on
//     lark-2). 1% grants negligible borrow power; the vault sizes its borrow off
//     the real-collateral delta and never leans on synth LTV.
//   - LT 98% is CONSUMED LIVE by the vault (`CollateralVault.synthLtBps()` reads
//     bits 16-31 of this reserve's config bitmap). It is not a deploy parameter,
//     so this proposal is the single source of truth for it — and until this
//     batch lands, every `deposit` reverts `SynthReserveNotListed`.
//   - registered as an Erc20 substrate asset so the EVM ERC20 precompile bridges
//     it. MUST be registered BEFORE initReserves (HDCL lesson: the precompile
//     reads decimals from the registry, so initReserves reverts otherwise).
const SYNTH_ASSET_ID = Number(process.env.PROPELLER_SYNTH_ASSET_ID || 5550);
const SYNTH_LT = "9800"; // 98% — read live by the vault
const SYNTH_LTV = "100"; // 1% — must be > 0 (see above), still ~zero borrow power
const SYNTH_BONUS = "10100"; // 1%
const SYNTH_SUPPLY_CAP = "0"; // 0 = unlimited

// ── Router route for the shared loop (HOLLAR ↔ aPRIME) ─────────────────────
// Mainnet ids. `configureDca` takes FIVE args — the sixth (period) went away with
// the pallet-DCA path in c0f9404; the loop now uses pallet_route::sell directly.
const ROUTE_HOLLAR = Number(process.env.PROPELLER_HOLLAR_ID || 222);
const ROUTE_PRIME = Number(process.env.PROPELLER_PRIME_ID || 43);
const ROUTE_APRIME = Number(process.env.PROPELLER_APRIME_ID || 1043);
const ROUTE_POOL = Number(process.env.PROPELLER_PRIME_POOL_ID || 143);
// Permill. 8% is what lark-4 needed because pool-143's HOLLAR→PRIME rate sits
// ~1.1% off oracle-fair and the router rejects a tighter min-out. Tighten this
// once pool depth improves — it is the slippage bound on two PERMISSIONLESS
// entrypoints (`pokeBorrow`, `pokeRepay`), so it is a real risk parameter.
const ROUTE_SLIPPAGE_PPM = Number(process.env.PROPELLER_SLIPPAGE_PPM || 80000);

// Per-poke tranche caps (HOLLAR 18dp in, aPRIME 6dp out).
const DEPLOY_TRANCHE = process.env.PROPELLER_DEPLOY_TRANCHE || "5000";
const UNWIND_TRANCHE = process.env.PROPELLER_UNWIND_TRANCHE || "5000";

// Max slippage `compound` tolerates vs the oracle-fair output. Default 0 means
// the floor equals the exact oracle price, so EVERY compound reverts until set.
const COMPOUND_SLIPPAGE_BPS = Number(process.env.PROPELLER_COMPOUND_SLIPPAGE_BPS || 100);

const ROLE = {
  MINTER: "MINTER_ROLE",
  GUARDIAN: "GUARDIAN_ROLE",
};

task(
  `propeller`,
  `Propeller launch — list the synthetic reserve, wire the vaults, hand the guardian to the technical committee`
).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const poolConfigurator = await getPoolConfiguratorProxy();
  const api = await getApi();
  const hydrationTx = api.tx;

  // ── deployed contract addresses ─────────────────────────────────────────
  const resolve = async (env: string, deploymentId: string) => {
    if (process.env[env]) return process.env[env];
    try {
      return (await hre.deployments.get(deploymentId)).address;
    } catch {
      return undefined;
    }
  };

  const synth = await resolve("PROPELLER_SYNTH", "SyntheticToken-Propeller");
  if (!synth) {
    throw new Error(
      "SyntheticToken not deployed. Run script/DeploySynth.s.sol, then set PROPELLER_SYNTH=0x… " +
        "(or add deployments/<net>/SyntheticToken-Propeller.json)"
    );
  }
  const subLoop = await resolve("PROPELLER_SUBLOOP", "SubLoop-Propeller");
  const harvester = await resolve("PROPELLER_HARVESTER", "Harvester-Propeller");
  // One or more CollateralVaults, comma-separated. e.g. PROPELLER_VAULTS=0xETH,0xTBTC
  const vaults = (process.env.PROPELLER_VAULTS || process.env.PROPELLER_VAULT || "")
    .split(",")
    .map((v) => v.trim())
    .filter(Boolean);
  // The HydraAugustus swapper (REQ-SWAP). Optional: if unset the vaults keep
  // whatever they were deployed with and `compound` stays inert.
  const swapper = process.env.PROPELLER_SWAPPER;
  // Technical committee — receives GUARDIAN_ROLE (fast pause) on every contract.
  const guardian = process.env.PROPELLER_GUARDIAN || EMERGENCY_ADMIN[networkId];

  console.log("Propeller wiring inputs");
  console.log(`  synthetic  : ${synth}`);
  console.log(`  subLoop    : ${subLoop ?? "(not set — wiring skipped)"}`);
  console.log(`  harvester  : ${harvester ?? "(not set — wiring skipped)"}`);
  console.log(`  vaults     : ${vaults.length ? vaults.join(", ") : "(none set — wiring skipped)"}`);
  console.log(`  swapper    : ${swapper ?? "(not set — setSwapper skipped)"}`);
  console.log(`  guardian   : ${guardian ?? "(not set — GUARDIAN grants skipped)"}`);
  console.log(`  synth asset: ${SYNTH_ASSET_ID}`);
  console.log(`  route      : ${ROUTE_HOLLAR}/${ROUTE_PRIME}/${ROUTE_APRIME} via pool ${ROUTE_POOL} @ ${ROUTE_SLIPPAGE_PPM}ppm\n`);

  // ── ABIs ────────────────────────────────────────────────────────────────
  const { id, Interface } = utils;
  const accessI = new Interface(["function grantRole(bytes32,address)"]);
  const loopI = new Interface([
    "function registerVault(address)",
    "function setTranches(uint256,uint256)",
    "function configureDca(uint32,uint32,uint32,uint32,uint32)",
    "function setHarvester(address)",
  ]);
  const vaultI = new Interface([
    "function setCompoundSlippageBps(uint16)",
    "function setSwapper(address)",
  ]);
  const harvI = new Interface(["function addVault(address)"]);

  // Every EVM call is dispatched as the aave-manager so the ACL checks pass.
  const evm = (to: string, data: string, gasLimit = 1_000_000) =>
    addTransaction({ to, data, gasLimit });

  // ═════════════════════════════════════════════════════════════════════════
  // BATCH 1 — list the synthetic reserve
  // ═════════════════════════════════════════════════════════════════════════
  // Kept separate from the rest: initReserves alone is ~58e9 refTime, and one
  // combined batch trips scheduler.PermanentlyOverweight (observed on lark-2).
  const substrateTxs: any[] = [];

  const synthInfo: any = await api.query.assetRegistry.assets(SYNTH_ASSET_ID);
  if (!synthInfo.isSome) {
    console.log(`[1] register synthetic (asset ${SYNTH_ASSET_ID}) as Erc20 → ${synth}`);
    substrateTxs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: SYNTH_ASSET_ID,
          name: "Propeller Synthetic HOLLAR",
          assetType: "Erc20",
          existentialDeposit: "10000000000000000", // 0.01
          symbol: "psHOLLAR",
          decimals: 18,
          location: location(synth),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    console.log(`[1] synthetic asset ${SYNTH_ASSET_ID} already registered — skipping`);
  }

  // Idempotency: initReserves reverts on an already-initialised reserve, and
  // dispatchAsAaveManager swallows EVM reverts as ExecutedFailed events rather
  // than failing the extrinsic — so a re-run would "pass" with the reserve
  // silently unconfigured. Check first. (HDCL post-mortem #3.)
  const reservesList: string[] = await (async () => {
    try {
      const pool = await hre.ethers.getContractAt(
        ["function getReservesList() view returns (address[])"],
        (await hre.deployments.get(`Pool-Proxy-${MARKET_NAME}`)).address
      );
      return (await pool.getReservesList()).map((a: string) => a.toLowerCase());
    } catch {
      return [];
    }
  })();
  const synthAlreadyListed = reservesList.includes(synth.toLowerCase());

  if (!synthAlreadyListed) {
    console.log("[1] initReserves(synthetic)");
    const aTokenImpl = (await hre.deployments.get(`AToken-${MARKET_NAME}`)).address;
    const stableDebtImpl = (await hre.deployments.get(`StableDebtToken-${MARKET_NAME}`)).address;
    const variableDebtImpl = (await hre.deployments.get(`VariableDebtToken-${MARKET_NAME}`)).address;
    const rateStrategy = (await hre.deployments.get("ReserveStrategy-rateStrategyStables")).address;
    const treasury = (await hre.deployments.get(TREASURY_PROXY_ID)).address;
    const incentives = (await hre.deployments.get("IncentivesProxy")).address;

    const tx = await poolConfigurator.populateTransaction.initReserves(
      [
        {
          aTokenImpl,
          stableDebtTokenImpl: stableDebtImpl,
          variableDebtTokenImpl: variableDebtImpl,
          underlyingAssetDecimals: 18,
          interestRateStrategyAddress: rateStrategy,
          underlyingAsset: synth,
          treasury,
          incentivesController: incentives,
          aTokenName: "Propeller aSynth",
          aTokenSymbol: "aPSYNTH",
          variableDebtTokenName: "Propeller Variable Debt Synth",
          variableDebtTokenSymbol: "vdPSYNTH",
          stableDebtTokenName: "Propeller Stable Debt Synth",
          stableDebtTokenSymbol: "sdPSYNTH",
          params: "0x",
        },
      ],
      { gasLimit: 12_000_000 }
    );
    addTransaction(tx);
  } else {
    console.log(`[1] synthetic reserve already listed — skipping initReserves`);
  }

  // Substrate registration MUST precede the EVM initReserves.
  const batch1 = [
    ...substrateTxs,
    ...(await Promise.all(getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin })))),
  ];
  clearBatch();

  // ═════════════════════════════════════════════════════════════════════════
  // BATCH 2 — configure the synthetic reserve as collateral
  // ═════════════════════════════════════════════════════════════════════════
  console.log(`[2] configureReserveAsCollateral(LTV ${SYNTH_LTV}, LT ${SYNTH_LT}, bonus ${SYNTH_BONUS})`);
  addTransaction(
    await poolConfigurator.populateTransaction.configureReserveAsCollateral(
      synth, SYNTH_LTV, SYNTH_LT, SYNTH_BONUS, { gasLimit: 1_000_000 }
    )
  );

  console.log("[2] setReserveBorrowing(synthetic, false)");
  addTransaction(
    await poolConfigurator.populateTransaction.setReserveBorrowing(synth, false, { gasLimit: 1_000_000 })
  );

  console.log("[2] setSupplyCap(synthetic, unlimited)");
  addTransaction(
    await poolConfigurator.populateTransaction.setSupplyCap(synth, SYNTH_SUPPLY_CAP, { gasLimit: 1_000_000 })
  );

  console.log("[2] setAssetSources(synthetic → $1 fixed oracle)");
  {
    const oracleArtifact = await hre.deployments.get(`AaveOracle-${MARKET_NAME}`);
    const oracle = await hre.ethers.getContractAt(oracleArtifact.abi, oracleArtifact.address);
    addTransaction(
      await oracle.populateTransaction.setAssetSources([synth], [GHO_ORACLE_ADDRESS])
    );
  }

  const batch2 = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  clearBatch();

  // ═════════════════════════════════════════════════════════════════════════
  // BATCH 3 — wire the contracts + hand the guardian to the technical committee
  // ═════════════════════════════════════════════════════════════════════════
  let batch3: any[] = [];
  if (subLoop && harvester && vaults.length) {
    const MINTER = id(ROLE.MINTER);
    const GUARDIAN = id(ROLE.GUARDIAN);

    for (const vault of vaults) {
      console.log(`[3] synth.grantRole(MINTER_ROLE, ${vault})`);
      evm(synth, accessI.encodeFunctionData("grantRole", [MINTER, vault]));

      console.log(`[3] subLoop.registerVault(${vault})`);
      evm(subLoop, loopI.encodeFunctionData("registerVault", [vault]));

      console.log(`[3] vault.setCompoundSlippageBps(${COMPOUND_SLIPPAGE_BPS})`);
      evm(vault, vaultI.encodeFunctionData("setCompoundSlippageBps", [COMPOUND_SLIPPAGE_BPS]));

      if (swapper) {
        console.log(`[3] vault.setSwapper(${swapper})`);
        evm(vault, vaultI.encodeFunctionData("setSwapper", [swapper]));
      }

      console.log(`[3] harvester.addVault(${vault})`);
      evm(harvester, harvI.encodeFunctionData("addVault", [vault]));
    }

    console.log(`[3] subLoop.setTranches(${DEPLOY_TRANCHE} HOLLAR, ${UNWIND_TRANCHE} aPRIME)`);
    evm(
      subLoop,
      loopI.encodeFunctionData("setTranches", [
        hre.ethers.utils.parseUnits(DEPLOY_TRANCHE, 18),
        hre.ethers.utils.parseUnits(UNWIND_TRANCHE, 6),
      ])
    );

    console.log(
      `[3] subLoop.configureDca(${ROUTE_HOLLAR}, ${ROUTE_PRIME}, ${ROUTE_APRIME}, ${ROUTE_POOL}, ${ROUTE_SLIPPAGE_PPM})`
    );
    evm(
      subLoop,
      loopI.encodeFunctionData("configureDca", [
        ROUTE_HOLLAR, ROUTE_PRIME, ROUTE_APRIME, ROUTE_POOL, ROUTE_SLIPPAGE_PPM,
      ])
    );

    // MUST come before anything can call harvest(): SubLoop.harvest reverts
    // HarvesterUnset while this is address(0), so carry realisation is blocked
    // (it used to pay msg.sender instead — the whole loop carry claimable by
    // anyone in the deploy→wiring window).
    console.log(`[3] subLoop.setHarvester(${harvester})`);
    evm(subLoop, loopI.encodeFunctionData("setHarvester", [harvester]));

    // Two-tier governance: ADMIN stays with the slow econ-params track, GUARDIAN
    // (pause only) goes to the technical committee for fast response. initialize
    // granted GUARDIAN to the admin so the pause is never unowned; this delegates
    // it. Governance keeps its own copy — revoking it is a separate decision.
    if (guardian) {
      console.log(`[3] grantRole(GUARDIAN_ROLE, ${guardian}) on subLoop + every vault`);
      evm(subLoop, accessI.encodeFunctionData("grantRole", [GUARDIAN, guardian]));
      for (const vault of vaults) {
        evm(vault, accessI.encodeFunctionData("grantRole", [GUARDIAN, guardian]));
      }
    } else {
      console.log("[3] no guardian configured — GUARDIAN_ROLE stays with governance only");
    }

    batch3 = await Promise.all(getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin })));
    clearBatch();
  } else {
    console.log(
      "[3] skipped — set PROPELLER_SUBLOOP, PROPELLER_HARVESTER and PROPELLER_VAULTS to emit the wiring batch"
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Emit one preimage per batch
  // ═════════════════════════════════════════════════════════════════════════
  const decoder = new ProposalDecoder(hre);
  await decoder.init();

  const emit = async (label: string, txs: any[]) => {
    if (!txs.length) {
      console.log(`\n===== ${label}: EMPTY — nothing to do =====`);
      return;
    }
    const batchAll = await generateProposalV2(txs, false);
    console.log(`\n===== ${label} (${txs.length} calls, ${batchAll.method.encodedLength} bytes) =====`);
    console.log(batchAll.toHex());
    console.log(`\n--- ${label} decoded ---`);
    decoder.printTree(decoder.transformCall(batchAll.toHuman()));
  };

  await emit("BATCH 1 — list-reserve", batch1);
  await emit("BATCH 2 — configure", batch2);
  await emit("BATCH 3 — wire", batch3);

  console.log(`
Submit each batch as its own Root referendum, IN ORDER. They are split because
initReserves alone is ~58e9 refTime and a combined batchAll trips
scheduler.PermanentlyOverweight (observed on lark-2).

After enactment, run scripts/propeller/verify-readiness.ts before announcing —
dispatcher.dispatchAsAaveManager reports EVM reverts as ExecutedFailed EVENTS,
not extrinsic failures, so a batch can "succeed" with calls silently reverted.
`);
});
