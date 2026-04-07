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

  // Predict proxy addresses from PoolConfigurator nonce
  // stHDX init creates: aToken(n), stableDebt(n+1), variableDebt(n+2)
  // HOLLAR init creates: aToken(n+3), stableDebt(n+4), variableDebt(n+5)
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hre.ethers.provider.getTransactionCount(configuratorAddress);
  const sthdxATokenAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce,
  });
  const ghoATokenProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + 3,
  });
  const ghoVariableDebtProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + 5,
  });

  console.log("predicted stHDX aToken:", sthdxATokenAddress);
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
    const bucketCapacity = ethers.utils.parseUnits("1.0", 24); // 1M HOLLAR — TODO: set final value
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

  // Register stHDX (asset 670)
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

  // Register GIGAHDX (asset 67) — aToken receipt for stHDX deposits
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: GIGAHDX,
        name: "GIGAHDX",
        assetType: "Erc20",
        existentialDeposit: "3000000000000", // 3 GIGAHDX (12 decimals) ≈ 3 HDX
        symbol: "GIGAHDX",
        decimals: 12,
        location: location(sthdxATokenAddress),
        xcmRateLimit: null,
        isSufficient: true,
      })
    )
  );

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
