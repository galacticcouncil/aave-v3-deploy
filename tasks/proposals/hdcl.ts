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
  // Phase A: HDCL reserve initialization (standard Aave flow)
  // ===================================================================

  console.log("---------> init HDCL reserve");
  await hre.run("init-reserve", {
    symbol: "HDCL",
    batch: true,
  });

  console.log("---------> review reserve factors");
  await hre.run("review-reserve-factors", {
    fix: true,
    batch: true,
  });

  // Wrap HDCL EVM txs
  const hdclTxs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );
  txs.push(...hdclTxs);
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
  // When HDCL reserve is already initialized (on-chain at time of proposal
  // generation), the batch only inits HOLLAR so HOLLAR's aToken is at offset 0.
  // When HDCL init IS in the batch, HOLLAR's aToken is at offset 3.
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hre.ethers.provider.getTransactionCount(configuratorAddress);

  const HDCL_UNDERLYING = "0x0000000000000000000000000000000100000037";
  const pool = await hre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16,address aTokenAddress,address,address,address,uint128,uint128,uint128))",
    ],
    await poolAddressesProvider.getPool()
  );
  const reservesList: string[] = await pool.getReservesList();
  const hdclAlreadyInit = reservesList
    .map((a) => a.toLowerCase())
    .includes(HDCL_UNDERLYING.toLowerCase());
  const hollarOffset = hdclAlreadyInit ? 0 : 3;

  let hdclATokenAddress: string;
  if (hdclAlreadyInit) {
    hdclATokenAddress = (await pool.getReserveData(HDCL_UNDERLYING)).aTokenAddress;
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

  console.log(`HDCL already initialized on-chain: ${hdclAlreadyInit}`);
  console.log("HDCL aToken:", hdclATokenAddress);
  console.log("predicted GhoAToken proxy:", ghoATokenProxyAddress);
  console.log("predicted GhoVariableDebtToken proxy:", ghoVariableDebtProxyAddress);

  // Register as facilitator
  console.log("---------> register HDCL pool as HOLLAR facilitator");
  {
    const hollar = new hre.ethers.Contract(
      HOLLAR_ADDRESS,
      (await hre.deployments.get("HOLLAR")).abi,
      signer
    );
    const bucketCapacity = ethers.utils.parseUnits("1.0", 24); // 1M HOLLAR
    const tx = await hollar.populateTransaction.addFacilitator(
      ghoATokenProxyAddress,
      "HDCL",
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
  // Phase D: Substrate root transactions — asset registry + fee payment
  // ===================================================================

  const HDCL_ASSET_ID = 55;
  const AHDCL_ASSET_ID = 550;

  // Check existing registrations. batchAll reverts the whole batch if any call
  // fails, so registering already-existing assets would brick the proposal.
  const api = await getApi();
  const hdclInfo: any = await api.query.assetRegistry.assets(HDCL_ASSET_ID);
  const aHdclInfo: any = await api.query.assetRegistry.assets(AHDCL_ASSET_ID);

  if (!hdclInfo.isSome) {
    console.log("---------> register HDCL in asset registry");
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: HDCL_ASSET_ID,
          name: "HDCL",
          assetType: "Token",
          existentialDeposit: "20000000000000000", // 0.02 HDCL (18 decimals)
          symbol: "HDCL",
          decimals: 18,
          location: null,
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    console.log(`---------> HDCL (${HDCL_ASSET_ID}) already in asset registry — skipping register`);
  }

  if (!aHdclInfo.isSome) {
    console.log(`---------> register aHDCL (asset ${AHDCL_ASSET_ID}) pointing at HDCL aToken`);
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: AHDCL_ASSET_ID,
          name: "aHDCL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000", // 0.02 aHDCL (18 decimals)
          symbol: "aHDCL",
          decimals: 18,
          location: location(hdclATokenAddress),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    // Already registered — check if location matches our aToken, and update if stale.
    const locOnChain: any = await api.query.assetRegistry.assetLocations(AHDCL_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = hdclATokenAddress.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`---------> aHDCL (${AHDCL_ASSET_ID}) already points at aToken ${hdclATokenAddress} — skipping update`);
    } else {
      console.log(
        `---------> aHDCL (${AHDCL_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`
      );
      txs.push(
        hydrationTx.assetRegistry.update(
          AHDCL_ASSET_ID,
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

  // Enable HDCL and aHDCL as fee payment currencies
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: HDCL_ASSET_ID,
        price: "1000000000000000000", // TODO: set accurate HDCL/HDX price
      })
    )
  );
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({
        asset: AHDCL_ASSET_ID,
        price: "1000000000000000000", // TODO: set accurate aHDCL/HDX price
      })
    )
  );

  // ===================================================================
  // Phase E: Generate proposal preimage
  // ===================================================================
  const { whitelistedCall, proposal } = await generateProposalV2(txs, true);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("whitelisted call hash:");
  console.log(whitelistedCall.method.hash.toHex());
  console.log("\nProposal preimage:");
  console.log(proposal.method.toHex());
  console.log("\nDecoded proposal calls:");
  await decoder.decode(proposal.method.toHex());
});
