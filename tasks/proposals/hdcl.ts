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

// Known deployed addresses
const HOLLAR_ADDRESS = "0x531a654d1696ED52e7275A8cede955E82620f99a"; // GhoToken on Hydration
const GHO_ORACLE_ADDRESS = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8"; // GhoOracle (fixed $1)

task(
  `hdcl`,
  `HDCL launch — separate MM instance with HDCL collateral and HOLLAR borrowing`
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
  // Phase A: DCL collateral reserve initialization (standard Aave flow).
  // DCL is the substrate-registered name for the vault token. The aToken
  // proxy created by initReserves becomes the user-facing "HDCL" asset.
  // ===================================================================

  console.log("---------> init DCL reserve");
  await hre.run("init-reserve", {
    symbol: "DCL",
    batch: true,
  });

  console.log("---------> review reserve factors");
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  // Register the HDCL PoolAddressesProvider into the shared (main money-market)
  // PoolAddressesProviderRegistry. The registry is owned by the aave-manager
  // precompile, so the deploy step deferred this to governance — done here as
  // an aave-manager call. ProviderId 22222255 per markets/hdcl/index.ts.
  // Idempotent: skip if already registered (registerAddressesProvider reverts
  // on a duplicate id, which would brick the whole batchAll).
  {
    const HDCL_PROVIDER_ID = 22222255;
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
        `---------> HDCL provider ${poolAddressesProvider.address} already in registry ${registryArtifact.address} (id=${existingId.toString()}) — skipping`
      );
    } else {
      console.log(
        `---------> register HDCL provider ${poolAddressesProvider.address} into shared registry ${registryArtifact.address} (id ${HDCL_PROVIDER_ID})`
      );
      const tx = await registry.populateTransaction.registerAddressesProvider(
        poolAddressesProvider.address,
        HDCL_PROVIDER_ID,
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

  // Get pre-deployed GHO implementations for HDCL pool
  const ghoATokenImpl = await hre.deployments.get("GhoAToken-HDCL");
  const ghoStableDebtImpl = await hre.deployments.get("GhoStableDebtToken-HDCL");
  const ghoVariableDebtImpl = await hre.deployments.get("GhoVariableDebtToken-HDCL");
  const ghoInterestRateStrategy = await hre.deployments.get("GhoInterestRateStrategy-HDCL");
  const treasuryAddress = (await hre.deployments.get(TREASURY_PROXY_ID)).address;
  const incentivesController = (await hre.deployments.get("IncentivesProxy")).address;

  console.log("---------> init HOLLAR reserve in HDCL pool");
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
          aTokenName: "HDCL aHOLLAR",
          aTokenSymbol: "aHDCLHOLLAR",
          variableDebtTokenName: "HDCL Variable Debt HOLLAR",
          variableDebtTokenSymbol: "vdHDCLHOLLAR",
          stableDebtTokenName: "HDCL Stable Debt HOLLAR",
          stableDebtTokenSymbol: "sdHDCLHOLLAR",
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

  console.log("---------> set HOLLAR oracle in HDCL AaveOracle");
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
  // Phase C: Register HDCL as HOLLAR facilitator + cross-references
  // ===================================================================

  // Predict proxy addresses from PoolConfigurator nonce.
  // When DCL reserve is already initialized (on-chain at time of proposal
  // generation), the batch only inits HOLLAR so HOLLAR's aToken is at offset 0.
  // When DCL init IS in the batch, HOLLAR's aToken is at offset 3.
  // The DCL aToken's address is what we register as the user-facing "HDCL"
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

  let hdclATokenAddress: string;
  if (dclAlreadyInit) {
    hdclATokenAddress = (await pool.getReserveData(DCL_UNDERLYING)).aTokenAddress;
  } else {
    hdclATokenAddress = utils.getContractAddress({
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

  console.log(`DCL already initialized on-chain: ${dclAlreadyInit}`);
  console.log("HDCL aToken (asset 55, location target):", hdclATokenAddress);
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
      console.log("---------> register HDCL pool as HOLLAR facilitator");
      const bucketCapacity = utils.parseUnits("1.0", 24); // 1M HOLLAR
      const tx = await hollar.populateTransaction.addFacilitator(
        ghoATokenProxyAddress,
        "HDCL",
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
  //   55  = HDCL  → user-facing aToken (what users hold after auto-deposit).
  //                 Location → DCL aToken proxy (computed from PoolConfigurator
  //                 nonce above as `hdclATokenAddress`).
  //   550 = DCL   → underlying vault token. Location → vault proxy (read from
  //                 HDCLOracleAdapter.vault()).
  // Both registered as Erc20 so the substrate→EVM precompile bridges to the
  // EVM contract (without that, Pool.supply / transfers via the precompile
  // see zero substrate balance and revert).
  const HDCL_ATOKEN_ASSET_ID = 55;
  const DCL_ASSET_ID = 550;

  // Vault proxy address (DCL location target) — read from HDCLOracleAdapter so
  // this works on any network without hardcoding.
  const oracleAdapterArtifact = await hre.deployments.get("HDCLOracleAdapter");
  const oracleAdapterRO = await hre.ethers.getContractAt(
    ["function vault() view returns (address)"],
    oracleAdapterArtifact.address
  );
  const HDCL_VAULT_PROXY = await oracleAdapterRO.vault();
  console.log(`Vault proxy (DCL → asset 550 location): ${HDCL_VAULT_PROXY}`);
  console.log(`DCL aToken (HDCL → asset 55 location):  ${hdclATokenAddress}`);

  // Check existing registrations. batchAll reverts the whole batch if any call
  // fails, so registering already-existing assets would brick the proposal.
  const api = await getApi();
  const hdclATokenInfo: any = await api.query.assetRegistry.assets(HDCL_ATOKEN_ASSET_ID);
  const dclInfo: any = await api.query.assetRegistry.assets(DCL_ASSET_ID);

  // ---- DCL (asset 550): underlying vault → assetRegistry.register or update ----
  if (!dclInfo.isSome) {
    console.log(`---------> register DCL (asset ${DCL_ASSET_ID}) Erc20 → vault proxy`);
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: DCL_ASSET_ID,
          name: "DCL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000", // 0.02 DCL
          symbol: "DCL",
          decimals: 18,
          location: location(HDCL_VAULT_PROXY),
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
    const expectedKey = HDCL_VAULT_PROXY.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`---------> DCL (${DCL_ASSET_ID}) already at vault proxy ${HDCL_VAULT_PROXY} — skipping`);
    } else {
      console.log(
        `---------> DCL (${DCL_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`
      );
      txs.push(
        hydrationTx.assetRegistry.update(
          DCL_ASSET_ID,
          null, null, null, null, null, null, null,
          location(HDCL_VAULT_PROXY)
        )
      );
    }
  }

  // ---- HDCL (asset 55): aToken receipt → assetRegistry.register or update ----
  if (!hdclATokenInfo.isSome) {
    console.log(`---------> register HDCL (asset ${HDCL_ATOKEN_ASSET_ID}) Erc20 → DCL aToken proxy`);
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: HDCL_ATOKEN_ASSET_ID,
          name: "HDCL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000",
          symbol: "HDCL",
          decimals: 18,
          location: location(hdclATokenAddress),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    // Already registered — check if location matches our aToken, and update if stale.
    const locOnChain: any = await api.query.assetRegistry.assetLocations(HDCL_ATOKEN_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = hdclATokenAddress.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`---------> HDCL (${HDCL_ATOKEN_ASSET_ID}) already at aToken ${hdclATokenAddress} — skipping`);
    } else {
      console.log(
        `---------> HDCL (${HDCL_ATOKEN_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`
      );
      txs.push(
        hydrationTx.assetRegistry.update(
          HDCL_ATOKEN_ASSET_ID,
          null, // name
          null, // asset_type
          null, // existential_deposit
          null, // xcm_rate_limit
          null, // is_sufficient
          null, // symbol
          null, // decimals
          location(hdclATokenAddress) // location
        )
      );
    }
  }

  // Enable DCL and HDCL as fee payment currencies.
  // Copy HOLLAR's price (asset 222) since 1 DCL = 1 HOLLAR at launch and
  // all three tokens share 18 decimals. Read from 0.lark on 2026-04-23:
  //   multiTransactionPayment.acceptedCurrencies(222) = 10960000000000000000000
  // Skip if already accepted — multiTransactionPayment.addCurrency reverts
  // with AlreadyAccepted on duplicate, which would revert the whole batchAll.
  const HOLLAR_FEE_PRICE = "10960000000000000000000";
  const dclFee: any = await api.query.multiTransactionPayment.acceptedCurrencies(DCL_ASSET_ID);
  const hdclFee: any = await api.query.multiTransactionPayment.acceptedCurrencies(HDCL_ATOKEN_ASSET_ID);
  if (!dclFee.isSome) {
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({ asset: DCL_ASSET_ID, price: HOLLAR_FEE_PRICE })
      )
    );
  } else {
    console.log(`---------> DCL (${DCL_ASSET_ID}) already accepted as fee currency — skipping`);
  }
  if (!hdclFee.isSome) {
    txs.push(
      hydrationTx.multiTransactionPayment.addCurrency(
        ...Object.values({ asset: HDCL_ATOKEN_ASSET_ID, price: HOLLAR_FEE_PRICE })
      )
    );
  } else {
    console.log(`---------> HDCL (${HDCL_ATOKEN_ASSET_ID}) already accepted as fee currency — skipping`);
  }

  // Approve the HDCL Pool proxy as a managed-balance contract so users don't
  // need a separate ERC-20 approve() before pool.supply / repay. Idempotent:
  // skip if already in EVMAccounts.ApprovedContract.
  const poolProxyAddress = (await hre.deployments.get("Pool-Proxy-HDCL")).address;
  // Pallet name is `evmAccounts` in the current (mainnet / lark-2) runtime
  // metadata. (The 0.lark fork ran an older runtime that camelCased it as
  // `eVMAccounts`.) Fall back to the old casing so this works on both.
  const evmAccountsQuery = api.query.evmAccounts ?? api.query.eVMAccounts;
  const evmAccountsTx = hydrationTx.evmAccounts ?? hydrationTx.eVMAccounts;
  const approvedEntry: any = await evmAccountsQuery.approvedContract(poolProxyAddress);
  if (!approvedEntry.isSome) {
    console.log(`---------> approve Pool-Proxy-HDCL (${poolProxyAddress}) for managed-balance access`);
    txs.push(evmAccountsTx.approveContract(poolProxyAddress));
  } else {
    console.log(`---------> Pool-Proxy-HDCL already approved — skipping`);
  }

  // ===================================================================
  // Phase E: Generate proposal preimage
  // ===================================================================
  const { whitelistedCall, proposal } = await generateProposalV2(txs, true);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("whitelisted call hash:");
  console.log(whitelistedCall.hash.toHex());
  console.log("\nProposal preimage:");
  console.log(proposal.toHex());
  console.log("\nDecoded proposal calls:");
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
});
