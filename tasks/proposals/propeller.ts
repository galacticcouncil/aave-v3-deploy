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
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  TREASURY_PROXY_ID,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Fixed $1 oracle (reused for the synthetic — it is pegged $1 by design, like HOLLAR).
const GHO_ORACLE_ADDRESS = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";

// Propeller synthetic collateral.
//   - reserve: LTV 0 / LT 98% / borrowing disabled / non-isolation / $1 oracle
//     → supplied by the CollateralVault to floor each Main position's HF so the
//       principal is un-liquidatable at any collateral price.
//   - registered as an Erc20 substrate asset so the EVM ERC20 precompile bridges
//     it (matches the HDCL ordering requirement: register before initReserves).
const SYNTH_ASSET_ID = Number(process.env.PROPELLER_SYNTH_ASSET_ID || 5550);
const SYNTH_LT = "9800"; // 98%
const SYNTH_LTV = "0"; // grants zero borrow power
const SYNTH_BONUS = "10100"; // 1% (lt*bonus must stay ≤ 1e4 in pct terms)
const SYNTH_SUPPLY_CAP = "0"; // 0 = unlimited

task(
  `propeller`,
  `Propeller launch — list the synthetic collateral reserve (LTV 0 / LT 98 / no-borrow / $1)`
).setAction(async function (_, hre) {
  const { utils } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const poolAddressesProvider = await getPoolAddressesProvider();
  const poolConfigurator = await getPoolConfiguratorProxy();
  const hydrationTx = (await getApi()).tx;
  const api = await getApi();

  // The synthetic token must already be deployed (forge → SyntheticToken). Read
  // its address from the deployment record or PROPELLER_SYNTH env override.
  let synth = process.env.PROPELLER_SYNTH;
  if (!synth) {
    try {
      synth = (await hre.deployments.get("SyntheticToken-Propeller")).address;
    } catch {
      throw new Error(
        "SyntheticToken not deployed. Deploy it first (forge) and set PROPELLER_SYNTH=0x… or add deployments/<net>/SyntheticToken-Propeller.json"
      );
    }
  }
  console.log("Propeller synthetic:", synth);

  // Reuse the HDCL market's standard token implementations + a stable rate
  // strategy (borrowing is disabled, so the rate model is inert).
  const aTokenImpl = (await hre.deployments.get("AToken-HDCL")).address;
  const stableDebtImpl = (await hre.deployments.get("StableDebtToken-HDCL")).address;
  const variableDebtImpl = (await hre.deployments.get("VariableDebtToken-HDCL")).address;
  const rateStrategy = (await hre.deployments.get("ReserveStrategy-rateStrategyStables")).address;
  const treasury = (await hre.deployments.get(TREASURY_PROXY_ID)).address;
  const incentives = (await hre.deployments.get("IncentivesProxy")).address;

  const txs = [];

  // ── Substrate root: register the synthetic as an Erc20 asset (BEFORE
  //    initReserves — the EVM precompile reads metadata from the registry). ──
  const synthInfo: any = await api.query.assetRegistry.assets(SYNTH_ASSET_ID);
  if (!synthInfo.isSome) {
    console.log(`---------> register synthetic (asset ${SYNTH_ASSET_ID}) Erc20 → ${synth}`);
    txs.push(
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
    console.log(`---------> synthetic asset ${SYNTH_ASSET_ID} already registered — skipping`);
  }

  // ── aave-manager: initialize the synthetic reserve ──
  console.log("---------> init synthetic reserve");
  {
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
  }

  // LTV 0 / LT 98 / bonus 1% — synth·LT floors Main HF strictly above 1.
  console.log("---------> configure synthetic as collateral (LTV 0 / LT 98)");
  addTransaction(
    await poolConfigurator.populateTransaction.configureReserveAsCollateral(
      synth, SYNTH_LTV, SYNTH_LT, SYNTH_BONUS, { gasLimit: 1_000_000 }
    )
  );

  console.log("---------> disable borrowing on synthetic");
  addTransaction(
    await poolConfigurator.populateTransaction.setReserveBorrowing(synth, false, { gasLimit: 1_000_000 })
  );

  console.log("---------> supply cap");
  addTransaction(
    await poolConfigurator.populateTransaction.setSupplyCap(synth, SYNTH_SUPPLY_CAP, { gasLimit: 1_000_000 })
  );

  // $1 oracle source (reuse the fixed GhoOracle).
  console.log("---------> set synthetic oracle source ($1)");
  {
    const oracleArtifact = await hre.deployments.get(`AaveOracle-${MARKET_NAME}`);
    const oracle = await hre.ethers.getContractAt(oracleArtifact.abi, oracleArtifact.address);
    addTransaction(
      await oracle.populateTransaction.setAssetSources([synth], [GHO_ORACLE_ADDRESS])
    );
  }

  // ── contract wiring (governance owns the contracts → wire via aave-manager) ──
  // Set PROPELLER_SUBLOOP / PROPELLER_VAULT / PROPELLER_HARVESTER to the deployed
  // proxy addresses to fold the wiring into the same Root batch.
  const subLoop = process.env.PROPELLER_SUBLOOP;
  const vault = process.env.PROPELLER_VAULT;
  const harvester = process.env.PROPELLER_HARVESTER;
  if (subLoop && vault && harvester) {
    const { id, Interface } = utils;
    const MINTER = id("MINTER_ROLE");
    const KEEPER = id("KEEPER_ROLE");
    const synthI = new Interface(["function grantRole(bytes32,address)"]);
    const loopI = new Interface([
      "function registerVault(address)",
      "function setTranches(uint256,uint256)",
      "function configureDca(uint32,uint32,uint32,uint32,uint32,uint32)",
      "function grantRole(bytes32,address)",
    ]);
    const vaultI = new Interface(["function grantRole(bytes32,address)"]);
    const harvI = new Interface(["function addVault(address)"]);
    const add = (to, data) => addTransaction({ to, data, gasLimit: 1_000_000 });

    console.log("---------> wire: synth MINTER → vault");
    add(synth, synthI.encodeFunctionData("grantRole", [MINTER, vault]));
    console.log("---------> wire: subLoop.registerVault + tranches + DCA route");
    add(subLoop, loopI.encodeFunctionData("registerVault", [vault]));
    add(subLoop, loopI.encodeFunctionData("setTranches", [
      hre.ethers.utils.parseUnits("100", 18), hre.ethers.utils.parseUnits("100", 18),
    ]));
    // lark2 HOLLAR↔DCL route: hollar 222, DCL 550, aDCL(HDCL) 55, 2-Pool-HDCL 10055.
    add(subLoop, loopI.encodeFunctionData("configureDca", [222, 550, 55, 10055, 10, 10000]));
    console.log("---------> wire: KEEPER → harvester (subLoop + vault), addVault");
    add(subLoop, loopI.encodeFunctionData("grantRole", [KEEPER, harvester]));
    add(vault, vaultI.encodeFunctionData("grantRole", [KEEPER, harvester]));
    add(harvester, harvI.encodeFunctionData("addVault", [vault]));
  } else {
    console.log("---------> (no PROPELLER_SUBLOOP/VAULT/HARVESTER set — skipping contract wiring)");
  }

  // Wrap all EVM (PoolConfigurator/oracle/contract-wiring) txs as aave-manager calls.
  const evmTxs = await Promise.all(getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin })));
  clearBatch();

  // Substrate asset-registration must run BEFORE the EVM initReserves.
  const ordered = [...txs, ...evmTxs];

  const batchAll = await generateProposalV2(ordered, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("\nEncoded proposal (batchAll):");
  console.log(batchAll.toHex());
  console.log("\nDecoded proposal calls:");
  decoder.printTree(decoder.transformCall(batchAll.toHuman()));
});
