// @ts-nocheck
import {
  ConfigNames,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  generateProposalV2,
  getApi,
  location,
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
  `gigahdx`,
  `GIGAHDX launch — second MM instance with stHDX collateral and HOLLAR borrowing`
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
  // Phase A: stHDX reserve initialization (standard Aave flow)
  // ===================================================================

  console.log("---------> init stHDX reserve");
  await hre.run("init-reserve", {
    symbol: "STHDX",
    batch: true,
  });

  console.log("---------> review reserve factors");
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  // Wrap stHDX EVM txs
  const sthdxTxs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  txs.push(...sthdxTxs);
  clearBatch();

  // ===================================================================
  // Phase B: HOLLAR reserve initialization (GhoAToken pattern)
  // ===================================================================

  // Get pre-deployed GHO implementations for GIGAHDX pool
  const ghoATokenImpl = await hre.deployments.get("GhoAToken-GIGAHDX");
  const ghoStableDebtImpl = await hre.deployments.get("GhoStableDebtToken-GIGAHDX");
  const ghoVariableDebtImpl = await hre.deployments.get("GhoVariableDebtToken-GIGAHDX");
  const ghoInterestRateStrategy = await hre.deployments.get("GhoInterestRateStrategy-GIGAHDX");
  const treasuryAddress = (await hre.deployments.get(TREASURY_PROXY_ID)).address;
  const incentivesController = (await hre.deployments.get("IncentivesProxy")).address;

  console.log("---------> init HOLLAR reserve in GIGAHDX pool");
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
          aTokenName: "GIGAHDX aHOLLAR",
          aTokenSymbol: "aGIGAHDXHOLLAR",
          variableDebtTokenName: "GIGAHDX Variable Debt HOLLAR",
          variableDebtTokenSymbol: "vdGIGAHDXHOLLAR",
          stableDebtTokenName: "GIGAHDX Stable Debt HOLLAR",
          stableDebtTokenSymbol: "sdGIGAHDXHOLLAR",
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

  console.log("---------> set HOLLAR oracle in GIGAHDX AaveOracle");
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
  // Phase C: Register GIGAHDX as HOLLAR facilitator + cross-references
  // ===================================================================

  // Predict proxy addresses from PoolConfigurator nonce.
  // When stHDX reserve is already initialized (on-chain at time of proposal
  // generation), the batch only inits HOLLAR so HOLLAR's aToken is at offset 0.
  // When stHDX init IS in the batch, HOLLAR's aToken is at offset 3.
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hre.ethers.provider.getTransactionCount(configuratorAddress);

  const STHDX_UNDERLYING = "0x000000000000000000000000000000010000029e";
  const pool = await hre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16,address aTokenAddress,address,address,address,uint128,uint128,uint128))",
    ],
    await poolAddressesProvider.getPool()
  );
  const reservesList: string[] = await pool.getReservesList();
  const sthdxAlreadyInit = reservesList
    .map((a) => a.toLowerCase())
    .includes(STHDX_UNDERLYING.toLowerCase());
  const hollarOffset = sthdxAlreadyInit ? 0 : 3;

  let sthdxATokenAddress: string;
  if (sthdxAlreadyInit) {
    sthdxATokenAddress = (await pool.getReserveData(STHDX_UNDERLYING)).aTokenAddress;
  } else {
    sthdxATokenAddress = utils.getContractAddress({
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

  console.log(`stHDX already initialized on-chain: ${sthdxAlreadyInit}`);
  console.log("stHDX aToken:", sthdxATokenAddress);
  console.log("predicted GhoAToken proxy:", ghoATokenProxyAddress);
  console.log("predicted GhoVariableDebtToken proxy:", ghoVariableDebtProxyAddress);

  // Register as facilitator
  console.log("---------> register GIGAHDX as HOLLAR facilitator");
  {
    const hollar = new hre.ethers.Contract(
      HOLLAR_ADDRESS,
      (await hre.deployments.get("HOLLAR")).abi,
      signer
    );
    const bucketCapacity = utils.parseUnits("1.0", 24); // 1M HOLLAR — TODO: set final value
    const tx = await hollar.populateTransaction.addFacilitator(
      ghoATokenProxyAddress,
      "GIGAHDX",
      bucketCapacity,
      { gasLimit: 500_000 }
    );
    addTransaction(tx);
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
  // Phase D: Substrate root transactions — asset registry
  // ===================================================================

  const STHDX = 670;
  const GIGAHDX = 67;

  // Check existing registrations. batchAll reverts the whole batch if any call
  // fails, so registering already-existing assets would brick the proposal.
  const api = await getApi();
  const sthdxInfo: any = await api.query.assetRegistry.assets(STHDX);
  const gigaInfo: any = await api.query.assetRegistry.assets(GIGAHDX);

  if (!sthdxInfo.isSome) {
    console.log("---------> register stHDX in asset registry");
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: STHDX,
          name: "stHDX",
          assetType: "Token",
          existentialDeposit: "3000000000000", // 3 stHDX (12 decimals)
          symbol: "stHDX",
          decimals: 12,
          location: null,
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    console.log("---------> stHDX (670) already in asset registry — skipping register");
  }

  if (!gigaInfo.isSome) {
    console.log("---------> register GIGAHDX (asset 67) pointing at stHDX aToken");
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: GIGAHDX,
          name: "GIGAHDX",
          assetType: "Erc20",
          existentialDeposit: "3000000000000",
          symbol: "GIGAHDX",
          decimals: 12,
          location: location(sthdxATokenAddress),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    // Already registered — check if location matches our aToken, and update if stale.
    const locOnChain: any = await api.query.assetRegistry.assetLocations(GIGAHDX);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = sthdxATokenAddress.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`---------> GIGAHDX (67) already points at aToken ${sthdxATokenAddress} — skipping update`);
    } else {
      console.log(
        `---------> GIGAHDX (67) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`
      );
      txs.push(
        hydrationTx.assetRegistry.update(
          GIGAHDX,
          null, // name
          null, // asset_type
          null, // existential_deposit
          null, // xcm_rate_limit
          null, // is_sufficient
          null, // symbol
          null, // decimals
          location(sthdxATokenAddress) // location
        )
      );
    }
  }

  /*
  // TODO: enable fee payment
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: STHDX, price: "TODO" })
    )
  );
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: GIGAHDX, price: "TODO" })
    )
  );
  */

  // ===================================================================
  // Phase E: Generate proposal preimage
  // ===================================================================
  const { whitelistedCall, proposal } = await generateProposalV2(txs, true);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("whitelisted call hash:");
  console.log(whitelistedCall.hash.toString());
  console.log("proposal preimage:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(whitelistedCall.toHuman()));
});
