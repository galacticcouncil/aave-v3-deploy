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
import { buildStablepoolTxs } from "./bil-stablepool-lark";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Known deployed addresses
const HOLLAR_ADDRESS = "0x531a654d1696ED52e7275A8cede955E82620f99a"; // GhoToken on Hydration
const GHO_ORACLE_ADDRESS = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8"; // GhoOracle (fixed $1)

task(
  `bil`,
  `BIL launch — separate MM instance with BIL collateral and HOLLAR borrowing`
).setAction(async function (_, hre) {
  const { utils, ethers } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const poolAddressesProvider = await getPoolAddressesProvider();
  const poolConfigurator = await getPoolConfiguratorProxy();
  const hydrationTx = (await getApi()).tx;
  const { deployer } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(deployer);

  const txs = [];

  // ===================================================================
  // Phase A: BIL collateral reserve initialization (standard Aave flow).
  // BIL is the substrate-registered name for the vault token. The aToken
  // proxy created by initReserves becomes the user-facing "BIL" asset.
  // ===================================================================

  console.log("---------> init BIL reserve");
  await hre.run("init-reserve", {
    symbol: "BIL",
    batch: true,
  });

  console.log("---------> review reserve factors");
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  // Register the BIL PoolAddressesProvider into the shared (main money-market)
  // PoolAddressesProviderRegistry. The registry is owned by the aave-manager
  // precompile, so the deploy step deferred this to governance — done here as
  // an aave-manager call. ProviderId 22222255 per markets/bil/index.ts.
  // Idempotent: skip if already registered (registerAddressesProvider reverts
  // on a duplicate id, which would brick the whole batchAll).
  {
    const BIL_PROVIDER_ID = 22222255;
    const registryArtifact = await hre.deployments.get(
      "PoolAddressesProviderRegistry"
    );
    const registry = await hre.ethers.getContractAt(
      registryArtifact.abi,
      registryArtifact.address
    );
    const existingId = await registry.getAddressesProviderIdByAddress(
      poolAddressesProvider.address
    );
    if (existingId.gt(0)) {
      console.log(
        `---------> BIL provider ${poolAddressesProvider.address} already in registry ${registryArtifact.address} (id=${existingId.toString()}) — skipping`
      );
    } else {
      console.log(
        `---------> register BIL provider ${poolAddressesProvider.address} into shared registry ${registryArtifact.address} (id ${BIL_PROVIDER_ID})`
      );
      const tx = await registry.populateTransaction.registerAddressesProvider(
        poolAddressesProvider.address,
        BIL_PROVIDER_ID,
        { gasLimit: 1_000_000 }
      );
      addTransaction(tx);
    }
  }

  const dclTxs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  txs.push(...dclTxs);
  clearBatch();

  // ===================================================================
  // Phase B: HOLLAR reserve initialization (GhoAToken pattern)
  // ===================================================================

  // Get pre-deployed GHO implementations for BIL pool
  const ghoATokenImpl = await hre.deployments.get("GhoAToken-BIL");
  const ghoStableDebtImpl = await hre.deployments.get("GhoStableDebtToken-BIL");
  const ghoVariableDebtImpl = await hre.deployments.get("GhoVariableDebtToken-BIL");
  const ghoInterestRateStrategy = await hre.deployments.get("GhoInterestRateStrategy-BIL");
  const treasuryAddress = (await hre.deployments.get(TREASURY_PROXY_ID)).address;
  const incentivesController = (await hre.deployments.get("IncentivesProxy")).address;

  console.log("---------> init HOLLAR reserve in BIL pool");
  {
    const tx = await poolConfigurator.populateTransaction.initReserves(
      [
        {
          aTokenImpl: ghoATokenImpl.address,
          stableDebtTokenImpl: ghoStableDebtImpl.address,
          variableDebtTokenImpl: ghoVariableDebtImpl.address,
          underlyingAssetDecimals: 18,
          interestRateStrategyAddress: ghoInterestRateStrategy.address,
          underlyingAsset: HOLLAR_ADDRESS,
          treasury: treasuryAddress,
          incentivesController: incentivesController,
          aTokenName: "BIL aHOLLAR",
          aTokenSymbol: "aBILHOLLAR",
          variableDebtTokenName: "BIL Variable Debt HOLLAR",
          variableDebtTokenSymbol: "vdBILHOLLAR",
          stableDebtTokenName: "BIL Stable Debt HOLLAR",
          stableDebtTokenSymbol: "sdBILHOLLAR",
          params: "0x10",
        },
      ],
      { gasLimit: 10_000_000 }
    );
    addTransaction(tx);
  }

  console.log("---------> enable HOLLAR borrowing");
  {
    const tx = await poolConfigurator.populateTransaction.setReserveBorrowing(
      HOLLAR_ADDRESS,
      true,
      { gasLimit: 1_000_000 }
    );
    addTransaction(tx);
  }

  console.log("---------> set HOLLAR oracle in BIL AaveOracle");
  {
    const oracleArtifact = await hre.deployments.get(`AaveOracle-${MARKET_NAME}`);
    const oracle = await hre.ethers.getContractAt(oracleArtifact.abi, oracleArtifact.address);
    const tx = await oracle.populateTransaction.setAssetSources(
      [HOLLAR_ADDRESS],
      [GHO_ORACLE_ADDRESS]
    );
    addTransaction(tx);
  }

  // ===================================================================
  // Phase C: Register BIL as HOLLAR facilitator + cross-references
  // ===================================================================

  // Predict proxy addresses from PoolConfigurator nonce.
  // When BIL reserve is already initialized (on-chain at time of proposal
  // generation), the batch only inits HOLLAR so HOLLAR's aToken is at offset 0.
  // When BIL init IS in the batch, HOLLAR's aToken is at offset 3.
  // The BIL aToken's address is what we register as the user-facing "BIL"
  // asset in the substrate registry (asset id 55).
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hre.ethers.provider.getTransactionCount(configuratorAddress);

  const DCL_UNDERLYING = "0x0000000000000000000000000000000100000226"; // tokenAddress(550)
  const pool = await hre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16,address aTokenAddress,address,address,address,uint128,uint128,uint128))",
    ],
    await poolAddressesProvider.getPool()
  );
  const reservesList: string[] = await pool.getReservesList();
  const dclAlreadyInit = reservesList
    .map((a) => a.toLowerCase())
    .includes(DCL_UNDERLYING.toLowerCase());
  const hollarOffset = dclAlreadyInit ? 0 : 3;

  let bilATokenAddress: string;
  if (dclAlreadyInit) {
    bilATokenAddress = (await pool.getReserveData(DCL_UNDERLYING)).aTokenAddress;
  } else {
    bilATokenAddress = utils.getContractAddress({
      from: configuratorAddress,
      nonce: currentNonce,
    });
  }
  const ghoATokenProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset,
  });
  const ghoVariableDebtProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset + 2,
  });

  console.log(`BIL already initialized on-chain: ${dclAlreadyInit}`);
  console.log("BIL aToken (asset 55, location target):", bilATokenAddress);
  console.log("predicted GhoAToken proxy:", ghoATokenProxyAddress);
  console.log("predicted GhoVariableDebtToken proxy:", ghoVariableDebtProxyAddress);

  // Register as facilitator (skip if already added — HOLLAR.addFacilitator
  // reverts on duplicate).
  {
    const hollar = new hre.ethers.Contract(
      HOLLAR_ADDRESS,
      (await hre.deployments.get("HOLLAR")).abi,
      signer
    );
    const existing = await hollar.getFacilitator(ghoATokenProxyAddress);
    const existingCap = existing?.bucketCapacity ?? existing?.[0] ?? BigInt(0);
    if (BigInt(existingCap.toString()) > BigInt(0)) {
      console.log(
        `---------> HOLLAR facilitator already added for ${ghoATokenProxyAddress} (cap=${existingCap}) — skipping`
      );
    } else {
      console.log("---------> register BIL pool as HOLLAR facilitator");
      const bucketCapacity = utils.parseUnits("1.0", 24); // 1M HOLLAR
      const tx = await hollar.populateTransaction.addFacilitator(
        ghoATokenProxyAddress,
        "BIL",
        bucketCapacity,
        { gasLimit: 500_000 }
      );
      addTransaction(tx);
    }
  }

  // Set GHO cross-references
  console.log("---------> set GHO cross-references");
  {
    const ghoAToken = new hre.ethers.Contract(
      ghoATokenProxyAddress,
      ghoATokenImpl.abi,
      signer
    );

    const txSetVarDebt = await ghoAToken.populateTransaction.setVariableDebtToken(
      ghoVariableDebtProxyAddress
    );
    addTransaction(txSetVarDebt);

    const txSetTreasury = await ghoAToken.populateTransaction.updateGhoTreasury(
      treasuryAddress
    );
    addTransaction(txSetTreasury);
  }

  {
    const ghoVariableDebt = new hre.ethers.Contract(
      ghoVariableDebtProxyAddress,
      ghoVariableDebtImpl.abi,
      signer
    );

    const txSetAToken = await ghoVariableDebt.populateTransaction.setAToken(
      ghoATokenProxyAddress
    );
    addTransaction(txSetAToken);

    const zeroDiscountStrategy = await hre.deployments.get("ZeroDiscountRateStrategy");
    const txSetDiscountRate =
      await ghoVariableDebt.populateTransaction.updateDiscountRateStrategy(
        zeroDiscountStrategy.address
      );
    addTransaction(txSetDiscountRate);

    const txSetDiscountToken =
      await ghoVariableDebt.populateTransaction.updateDiscountToken(HOLLAR_ADDRESS);
    addTransaction(txSetDiscountToken);
  }

  // Wrap all HOLLAR EVM txs
  const hollarTxs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  txs.push(...hollarTxs);
  clearBatch();

  // ===================================================================
  // Phase D: Substrate root transactions — asset registry + fee payment +
  // approve MM contract for ERC-20 transferFrom.
  // ===================================================================

  // Asset-id allocation:
  //   55  = BIL  → user-facing aToken (what users hold after auto-deposit).
  //                 Location → BIL aToken proxy (computed from PoolConfigurator
  //                 nonce above as `bilATokenAddress`).
  //   550 = BIL   → underlying vault token. Location → vault proxy (read from
  //                 BILOracleAdapter.vault()).
  // Both registered as Erc20 so the substrate→EVM precompile bridges to the
  // EVM contract (without that, Pool.supply / transfers via the precompile
  // see zero substrate balance and revert).
  const BIL_ATOKEN_ASSET_ID = 55;
  const DCL_ASSET_ID = 550;

  // Vault proxy address (BIL location target) — read from BILOracleAdapter so
  // this works on any network without hardcoding.
  const oracleAdapterArtifact = await hre.deployments.get("BILOracleAdapter");
  const oracleAdapterRO = await hre.ethers.getContractAt(
    ["function vault() view returns (address)"],
    oracleAdapterArtifact.address
  );
  const BIL_VAULT_PROXY = await oracleAdapterRO.vault();
  console.log(`Vault proxy (BIL → asset 550 location): ${BIL_VAULT_PROXY}`);
  console.log(`BIL aToken (BIL → asset 55 location):  ${bilATokenAddress}`);

  // Check existing registrations. batchAll reverts the whole batch if any call
  // fails, so registering already-existing assets would brick the proposal.
  const api = await getApi();
  const bilATokenInfo: any = await api.query.assetRegistry.assets(BIL_ATOKEN_ASSET_ID);
  const dclInfo: any = await api.query.assetRegistry.assets(DCL_ASSET_ID);

  // ---- BIL (asset 550): underlying vault → assetRegistry.register or update ----
  if (!dclInfo.isSome) {
    console.log(`---------> register BIL (asset ${DCL_ASSET_ID}) Erc20 → vault proxy`);
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: DCL_ASSET_ID,
          name: "BIL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000", // 0.02 BIL
          symbol: "BIL",
          decimals: 18,
          location: location(BIL_VAULT_PROXY),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    const locOnChain: any = await api.query.assetRegistry.assetLocations(DCL_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = BIL_VAULT_PROXY.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`---------> BIL (${DCL_ASSET_ID}) already at vault proxy ${BIL_VAULT_PROXY} — skipping`);
    } else {
      console.log(
        `---------> BIL (${DCL_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`
      );
      txs.push(
        hydrationTx.assetRegistry.update(
          DCL_ASSET_ID,
          null, null, null, null, null, null, null,
          location(BIL_VAULT_PROXY)
        )
      );
    }
  }

  // ---- aBIL (asset 55): aToken receipt → assetRegistry.register or update ----
  // Distinct name+symbol from the underlying BIL (asset 550): assetRegistry
  // enforces unique names+symbols, so the aToken receipt is registered as aBIL.
  if (!bilATokenInfo.isSome) {
    console.log(`---------> register aBIL (asset ${BIL_ATOKEN_ASSET_ID}) Erc20 → BIL aToken proxy`);
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: BIL_ATOKEN_ASSET_ID,
          name: "aBIL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000",
          symbol: "aBIL",
          decimals: 18,
          location: location(bilATokenAddress),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    // Already registered — check if location matches our aToken, and update if stale.
    const locOnChain: any = await api.query.assetRegistry.assetLocations(BIL_ATOKEN_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = bilATokenAddress.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`---------> BIL (${BIL_ATOKEN_ASSET_ID}) already at aToken ${bilATokenAddress} — skipping`);
    } else {
      console.log(
        `---------> BIL (${BIL_ATOKEN_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`
      );
      txs.push(
        hydrationTx.assetRegistry.update(
          BIL_ATOKEN_ASSET_ID,
          null, // name
          null, // asset_type
          null, // existential_deposit
          null, // xcm_rate_limit
          null, // is_sufficient
          null, // symbol
          null, // decimals
          location(bilATokenAddress) // location
        )
      );
    }
  }

  // Enable BIL and BIL as fee payment currencies.
  // Copy HOLLAR's price (asset 222) since 1 BIL = 1 HOLLAR at launch and
  // all three tokens share 18 decimals. Read from 0.lark on 2026-04-23:
  //   multiTransactionPayment.acceptedCurrencies(222) = 10960000000000000000000
  // Skip if already accepted — multiTransactionPayment.addCurrency reverts
  // with AlreadyAccepted on duplicate, which would revert the whole batchAll.
  const HOLLAR_FEE_PRICE = "10960000000000000000000";
  const dclFee: any = await api.query.multiTransactionPayment.acceptedCurrencies(DCL_ASSET_ID);
  const bilFee: any = await api.query.multiTransactionPayment.acceptedCurrencies(BIL_ATOKEN_ASSET_ID);
  if (!dclFee.isSome) {
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({ asset: DCL_ASSET_ID, price: HOLLAR_FEE_PRICE })
      )
    );
  } else {
    console.log(`---------> BIL (${DCL_ASSET_ID}) already accepted as fee currency — skipping`);
  }
  if (!bilFee.isSome) {
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({ asset: BIL_ATOKEN_ASSET_ID, price: HOLLAR_FEE_PRICE })
      )
    );
  } else {
    console.log(`---------> BIL (${BIL_ATOKEN_ASSET_ID}) already accepted as fee currency — skipping`);
  }

  // Approve the BIL Pool proxy as a managed-balance contract so users don't
  // need a separate ERC-20 approve() before pool.supply / repay. Idempotent:
  // skip if already in EVMAccounts.ApprovedContract.
  const poolProxyAddress = (await hre.deployments.get("Pool-Proxy-BIL")).address;
  // Pallet name is `evmAccounts` in the current (mainnet / lark-2) runtime
  // metadata. (The 0.lark fork ran an older runtime that camelCased it as
  // `eVMAccounts`.) Fall back to the old casing so this works on both.
  const evmAccountsQuery = api.query.evmAccounts ?? api.query.eVMAccounts;
  const evmAccountsTx = hydrationTx.evmAccounts ?? hydrationTx.eVMAccounts;
  const approvedEntry: any = await evmAccountsQuery.approvedContract(poolProxyAddress);
  if (!approvedEntry.isSome) {
    console.log(`---------> approve Pool-Proxy-BIL (${poolProxyAddress}) for managed-balance access`);
    txs.push(evmAccountsTx.approveContract(poolProxyAddress));
  } else {
    console.log(`---------> Pool-Proxy-BIL already approved — skipping`);
  }

  // ===================================================================
  // Phase E.5: Stablepool bootstrap — BIL/HOLLAR fast-withdrawal path
  // ===================================================================
  // Registers the 2-Pool-BIL LP asset (10055), creates the stableswap
  // (assets [55, 222], A=100, fee=0.10%, MMOracle peg), and bootstraps
  // 300K BIL / 300K HOLLAR from the Treasury (Treasury borrows 600K
  // HOLLAR from the main MM, zaps half into BIL, pairs both into the
  // pool, all scheduled 1 block after pool creation).
  //
  // Idempotent: pre-flight throws if asset 10055 already exists. On
  // re-runs against a network where the stablepool is done, skip with a
  // warning rather than aborting the whole proposal — the main BIL
  // launch piece may still need re-application.
  try {
    // inline=true skips the "asset 55 is registered" precondition since
    // we register it earlier in this same batch — runtime ordering is
    // preserved by batchAll executing sequentially.
    const stablepoolTxs = await buildStablepoolTxs(hre, { inline: true });
    txs.push(...stablepoolTxs);
    console.log(`Phase E.5: appended ${stablepoolTxs.length} stablepool txs`);
  } catch (e: any) {
    if (/already registered/i.test(e?.message ?? "")) {
      console.log(`Phase E.5: stablepool already live — skipping (${e.message})`);
    } else {
      throw e;
    }
  }

  // Reorder: the substrate registration of BIL (asset 550 → vault proxy) MUST
  // run *before* EVM PoolConfigurator.initReserves(BIL). The substrate→EVM
  // ERC20 precompile reads asset metadata (decimals…) from the registry, so
  // initReserves reverts if the underlying isn't registered as Erc20 yet.
  // batchAll runs sequentially, so we hoist the BIL register/update tx to
  // position 0. dispatcher.dispatchAsAaveManager swallows EVM reverts as
  // ExecutedFailed events (not extrinsic failure), so this is the only way to
  // catch the ordering bug — the proposal would otherwise "pass" with the
  // collateral side silently missing.
  {
    const dclRegIdx = txs.findIndex((t: any) => {
      const sec = t?.method?.section;
      const meth = t?.method?.method;
      if (sec !== "assetRegistry") return false;
      if (meth !== "register" && meth !== "update") return false;
      return Number(t?.args?.[0]?.toString?.() ?? -1) === DCL_ASSET_ID;
    });
    if (dclRegIdx > 0) {
      const [dclRegTx] = txs.splice(dclRegIdx, 1);
      txs.unshift(dclRegTx);
      console.log(`reordered: BIL substrate register moved ${dclRegIdx} → 0`);
    }
  }

  // ===================================================================
  // Phase E: Generate proposal preimage
  // ===================================================================
  // Submitted on the Root track as the bare `utility.batchAll` — no TC
  // whitelist wrapper. Feed this hex to chopsticks fast-execute or the
  // referenda.submit flow.
  const batchAll = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("Encoded proposal (batchAll):");
  console.log(batchAll.toHex());
  console.log("\nDecoded proposal calls:");
  decoder.printTree(decoder.transformCall(batchAll.toHuman()));
});
