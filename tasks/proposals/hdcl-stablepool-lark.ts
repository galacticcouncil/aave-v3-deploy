// @ts-nocheck
import * as fs from "fs";
import * as path from "path";

import {
  aaveManagerCall,
  generateProposalV2,
  getApi,
  dispatchAs,
  evmAddress,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Standalone task: builds JUST the stablepool delta as its own proposal.
// Used to patch lark-2 (where the main hdcl.ts proposal already ran without
// the stablepool component) up to parity with what mainnet's main proposal
// will produce. Mainnet doesn't run this — it gets the same bootstrap as
// part of hdcl.ts (`buildStablepoolTxs` is also imported there).
task(
  `hdcl-stablepool-patch`,
  `Stablepool delta for HDCL — registers 2-Pool-HDCL (10055), creates the ` +
    `HDCL/HOLLAR stableswap, and bootstraps 300K/300K liquidity from the ` +
    `Treasury (via 600K HOLLAR borrow on main MM + zap). Use this when the ` +
    `main hdcl.ts proposal has already executed on a network and only the ` +
    `stablepool piece is missing (lark-2).`
).setAction(async function (_, hre) {
  const preimage = await buildHdclStablepoolProposal(hre);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("\n===== Proposal preimage =====");
  console.log(preimage.toHex());
  console.log("\n===== Decoded proposal calls =====");
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});

/**
 * Build the HDCL stablepool launch proposal preimage. Returns the
 * `extrinsic.method` (a single SubmittableExtrinsic) suitable for passing
 * to `referenda.submit` via a Lookup preimage.
 *
 * Exported so submit scripts can re-build without going through the
 * hardhat task printer.
 */
export async function buildHdclStablepoolProposal(hre: any) {
  const txs = await buildStablepoolTxs(hre);
  return await generateProposalV2(txs, false);
}

/**
 * Build the raw tx list for the stablepool bootstrap. Returns
 * SubmittableExtrinsics in batch-order, ready to be concatenated onto any
 * larger `utility.batchAll` (e.g. by `hdcl.ts` to fold the bootstrap into
 * the main launch proposal).
 *
 * Idempotent at the proposal level: pre-flight checks throw if the
 * stablepool is already live (asset 10055 registered), so callers can
 * catch and skip when running against a network where it's done.
 */
export async function buildStablepoolTxs(hre: any) {
  const { utils } = hre.ethers;

  // ====================================================================
  // Configuration
  // ====================================================================

  // Asset IDs (mainnet-aligned naming, used on lark-2 too as of refs #383+):
  //   HDCL (asset 55,  precompile 0x…0037) — aToken receipt; what users hold
  //   DCL  (asset 550, precompile 0x…0226) — vault underlying; the pool's reserve
  //   2-Pool-HDCL (asset 10055)            — NEW stableswap LP token
  // The stableswap pair is (HDCL aToken ↔ HOLLAR) so a redeem-without-queue
  // path means swapping the aToken receipt directly into HOLLAR.
  const HDCL = 55;     // aToken receipt — what users hold
  const HOLLAR = 222;
  const POOL_LP = 10055;

  // Treasury substrate address. Same on lark since lark forks mainnet.
  // Reused from heurc-launch / hollar-pools-launch.
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  // Stableswap pool params — see HDCL-MAINNET-HANDOVER.md "Mainnet
  // single-batch launch composition" for the rationale on each.
  const AMPLIFICATION = 100;
  const FEE = 1000; // 0.1%
  const MAX_PEG_UPDATE = 200; // gigasol-style "≥10× expected APY"

  // Bootstrap amounts. Treasury borrows 600K HOLLAR from the main MM,
  // pairs 300K HOLLAR with 300K HDCL (zap-minted) into the new stablepool.
  const HOLLAR_BORROW_AMOUNT = utils.parseEther("600000").toString();
  const HOLLAR_DEPOSIT_AMOUNT = utils.parseEther("300000").toString();
  const HOLLAR_PAIR_AMOUNT = utils.parseEther("300000").toString();

  // ====================================================================
  // API + deployment lookups
  // ====================================================================
  const hydrationApi = await getApi();
  const hydrationTx = hydrationApi.tx;

  const oracleAdapter = (await hre.deployments.get("HDCLOracleAdapter"))
    .address;
  const zapAddr = (await hre.deployments.get("HDCLDepositZap")).address;
  const hollarAddr = (await hre.deployments.get("HOLLAR")).address;

  // Main MM Pool-Proxy lives at the canonical mainnet address. Lark
  // inherits this via the fork; the artifact only exists in
  // deployments/hydration/, not in the per-network HDCL deployments dir.
  const mainPoolAddr = readMainHydrationPool(__dirname);

  console.log("HDCLOracleAdapter:    ", oracleAdapter);
  console.log("HDCLDepositZap:       ", zapAddr);
  console.log("HOLLAR:               ", hollarAddr);
  console.log("Main MM Pool-Proxy:   ", mainPoolAddr);

  // ====================================================================
  // Pre-flight checks — fail fast if state isn't right
  // ====================================================================

  const lpInfo: any =
    await hydrationApi.query.assetRegistry.assets(POOL_LP);
  if (lpInfo.isSome) {
    throw new Error(
      `Asset ${POOL_LP} (2-Pool-HDCL) is already registered. ` +
        `This proposal is single-shot — skip if the stablepool is already live.`
    );
  }

  const hdclInfo: any = await hydrationApi.query.assetRegistry.assets(HDCL);
  if (!hdclInfo.isSome) {
    throw new Error(
      `Asset ${HDCL} (HDCL aToken receipt) is not registered. The hdcl.ts ` +
        `proposal must execute first.`
    );
  }

  // HDCLDepositZap must be max-approved on HOLLAR→Vault.
  const vaultProxyAddr = await readVaultAddress(hre, oracleAdapter);
  const zapHollarAllowance = await new hre.ethers.Contract(
    hollarAddr,
    [
      "function allowance(address owner, address spender) view returns (uint256)",
    ],
    hre.ethers.provider
  ).allowance(zapAddr, vaultProxyAddr);
  if (zapHollarAllowance.lt(BigInt(HOLLAR_DEPOSIT_AMOUNT))) {
    throw new Error(
      `HDCLDepositZap's HOLLAR→Vault allowance (${zapHollarAllowance}) is ` +
        `below the deposit amount (${HOLLAR_DEPOSIT_AMOUNT}). The zap should ` +
        `have been deployed with a max-approve to the vault — verify the deploy.`
    );
  }

  // Treasury must have ≥600K HOLLAR worth of borrowing capacity on the
  // main MM. availableBorrowsBase is in 8-decimal USD units; HOLLAR is
  // $-pegged so 600K HOLLAR ≈ 600_000 × 1e8 base units.
  const treasuryEvm = await evmAddress(treasury);
  const mainPoolRO = new hre.ethers.Contract(
    mainPoolAddr,
    [
      "function getUserAccountData(address) view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor)",
    ],
    hre.ethers.provider
  );
  const acct = await mainPoolRO.getUserAccountData(treasuryEvm);
  const availableBorrowsBase = acct.availableBorrowsBase.toBigInt();
  const required600KBase = 600_000n * 10n ** 8n;
  if (availableBorrowsBase < required600KBase) {
    console.warn(
      `\n!!! WARNING: Treasury main-MM availableBorrowsBase (${availableBorrowsBase}) ` +
        `< 600K HOLLAR (${required600KBase}).\n` +
        `    The borrow step will revert. Verify Treasury's main-MM collateral ` +
        `before submitting.\n`
    );
  } else {
    console.log(
      `Treasury main-MM borrow capacity OK: ${availableBorrowsBase} ` +
        `(need ${required600KBase})`
    );
  }

  // ====================================================================
  // Predict HDCL mint amount from a 300K HOLLAR deposit
  // ====================================================================
  // The zap mints HDCL aToken at vault.exchangeRate at execution time.
  // exchangeRate increases monotonically as yield accrues, so the actual
  // mint at execution will be SLIGHTLY LESS than predicted at proposal-build.
  //
  // Buffer: 7 days of yield at 18% APY ≈ 0.345%; we use 0.3% (just under
  // 7 days) per the user's spec. If the proposal sits unsubmitted for more
  // than ~6 days, re-build to refresh the estimate.
  const vaultRO = new hre.ethers.Contract(
    vaultProxyAddr,
    ["function exchangeRate() view returns (uint256)"],
    hre.ethers.provider
  );
  const exchangeRateWad = (await vaultRO.exchangeRate()).toBigInt();
  const ONE_WAD = 10n ** 18n;
  const expectedHdcl =
    (BigInt(HOLLAR_DEPOSIT_AMOUNT) * ONE_WAD) / exchangeRateWad;
  // Under-promise by 0.3% (≈ 7 days of 18% APY yield, minus a little).
  const HDCL_SUPPLY_AMOUNT = ((expectedHdcl * 997n) / 1000n).toString();
  console.log(
    `vault.exchangeRate at build: ${exchangeRateWad}; expected mint: ${expectedHdcl}; ` +
      `safe-supply (0.3% buffer): ${HDCL_SUPPLY_AMOUNT}`
  );

  // ====================================================================
  // 2-Pool-HDCL fee-currency price — reuse HOLLAR's price
  // ====================================================================
  // 1 LP share ≈ 1 HOLLAR at launch (pool bootstrapped 50/50 around 1:1 peg).
  const hollarFee: any =
    await hydrationApi.query.multiTransactionPayment.acceptedCurrencies(
      HOLLAR
    );
  if (!hollarFee.isSome) {
    throw new Error(
      `HOLLAR (${HOLLAR}) is not a registered fee currency. Cannot derive ` +
        `2-Pool-HDCL fee price.`
    );
  }
  const HOLLAR_FEE_PRICE = hollarFee.unwrap().toString();
  console.log("HOLLAR fee price (reused for 2-Pool-HDCL):", HOLLAR_FEE_PRICE);

  // ====================================================================
  // Resolve HDCL pool's AaveOracle (for the consolidation step below)
  // ====================================================================
  const hdclAaveOracleAddr = (
    await hre.deployments.get("AaveOracle-HDCL")
  ).address;
  // The HDCL pool's reserve is DCL (asset 550 → precompile 0x…0226).
  // setAssetSources is keyed by the reserve underlying address.
  const DCL_PRECOMPILE = "0x0000000000000000000000000000000100000226";
  console.log("HDCL AaveOracle:      ", hdclAaveOracleAddr);

  // ====================================================================
  // Build proposal
  // ====================================================================
  const txs: any[] = [];
  const last: any[] = [];

  // -------- 0. Consolidate HDCL pool's oracle to the new (V3-compliant) oracle --------
  // The original HDCLOracleAdapter only implemented the legacy IEACAggregatorProxy
  // (latestAnswer). Hydration's stableswap pallet's MMOracle peg-source resolver
  // calls latestRoundData() (Chainlink V3), so we re-deployed HDCLOracleAdapter
  // with the full V3 interface. Both Aave and stableswap should now use the new
  // oracle so there's only one source of truth on lark.
  //
  // Encoded as `dispatcher.dispatchAsAaveManager(evm.call(setAssetSources, ...))`
  // — same admin-EVM pattern hdcl.ts uses for its other Aave Manager calls.
  // Idempotent: setAssetSources is a plain assignment, safe to re-run.
  console.log(
    `---------> consolidate HDCL AaveOracle source for ${DCL_PRECOMPILE} → ${oracleAdapter}`
  );
  {
    const aaveOracleIface = new utils.Interface([
      "function setAssetSources(address[] assets, address[] sources)",
    ]);
    const setSourcesData = aaveOracleIface.encodeFunctionData(
      "setAssetSources",
      [[DCL_PRECOMPILE], [oracleAdapter]]
    );
    txs.push(
      await aaveManagerCall({
        from: "0xaa7e0000000000000000000000000000000aa7e0",
        to: hdclAaveOracleAddr,
        data: setSourcesData,
        gasLimit: "300000",
      })
    );
  }

  // -------- 1. Register 2-Pool-HDCL (10055) --------
  console.log("---------> register 2-Pool-HDCL (10055)");
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: POOL_LP,
        name: "2-Pool-HDCL",
        assetType: "StableSwap",
        existentialDeposit: "17241379310344828",
        symbol: "2-Pool-HDCL",
        decimals: 18,
        location: null,
        xcmRateLimit: utils.parseEther("1500000").toString(),
        isSufficient: true,
      })
    )
  );

  // -------- 2. Allow 2-Pool-HDCL as fee currency --------
  console.log("---------> add 2-Pool-HDCL as fee currency");
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: POOL_LP, price: HOLLAR_FEE_PRICE })
    )
  );

  // -------- 3. Create stableswap pool (HDCL ↔ HOLLAR) --------
  // Assets sorted ascending: HDCL(55) < HOLLAR(222). Sort order matters —
  // the runtime enforces it and the peg-source array follows the same order.
  // Peg sources:
  //   HDCL   (sorted first):  MMOracle = HDCLOracleAdapter, which reads
  //                           vault.exchangeRate() scaled to 8 dec. The
  //                           aToken is 1:1 redeemable for the underlying
  //                           (Aave V3 scaledBalance × liquidityIndex), so
  //                           1 HDCL = vault.exchangeRate() HOLLAR. Same
  //                           oracle the Aave reserve uses.
  //   HOLLAR (sorted second): fixed 1:1 base reference.
  // maxPegUpdate=200 follows gigasol's ≥10× APY rule for HDCL's ~18% APY.
  console.log("---------> create stableswap pool (HDCL ↔ HOLLAR)");
  txs.push(
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: POOL_LP,
        assets: [HDCL, HOLLAR],
        amplification: AMPLIFICATION,
        fee: FEE,
        pegSource: [
          { MMOracle: oracleAdapter }, // HDCL (sorted first)
          { value: [1, 1] }, // HOLLAR (sorted second) — fixed 1:1 base
        ],
        maxPegUpdate: MAX_PEG_UPDATE,
      })
    )
  );

  // -------- 4. Treasury bootstrap (scheduled +1 block) --------
  // Pool must exist before liquidity flows, so the bootstrap is scheduled
  // 1 block after the proposal's pool-creation step.
  //
  // Steps (all dispatched as Treasury):
  //   4a. EVM:       MainPool.borrow(HOLLAR, 600K, variable, 0, treasury)
  //                  borrow happens on the MAIN money market, against
  //                  Treasury's existing collateral there.
  //   4b. EVM:       HOLLAR.approve(zap, 300K)
  //   4c. EVM:       zap.depositAndSupply(300K HOLLAR) → mints ~300K HDCL aToken atomically
  //   4d. Substrate: stableswap.addAssetsLiquidity([HDCL: HDCL_SUPPLY_AMOUNT, HOLLAR: 300K])
  //
  // Treasury's bound EVM address is derived from its substrate AccountId
  // (default truncation). pallet_evm's source-validation requires the
  // dispatcher's bound address to match the EVM call's `source` field.

  console.log("Treasury bound EVM address:", treasuryEvm);

  // 4a. Treasury borrows 600K HOLLAR from the main MM.
  // Aave V3 borrow: msg.sender pays the debt and receives the asset;
  // onBehalfOf is the user whose collateral is used. For self-borrow,
  // msg.sender == onBehalfOf == Treasury.
  const mainPoolIface = new utils.Interface([
    "function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)",
  ]);
  const borrowCalldata = mainPoolIface.encodeFunctionData("borrow", [
    hollarAddr,
    HOLLAR_BORROW_AMOUNT,
    2, // interestRateMode = variable (HOLLAR via GhoAToken facilitator requires variable)
    0, // referralCode
    treasuryEvm, // onBehalfOf = Treasury itself
  ]);
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.evm.call(
        treasuryEvm,
        mainPoolAddr,
        borrowCalldata,
        "0", // value
        "1500000", // gasLimit — Aave V3 borrow is heavy (interest, debt mint, GHO mint)
        "600000000", // gasPrice
        undefined, // maxPriorityFeePerGas
        undefined, // nonce
        [], // accessList
        []
      )
    )
  );

  // 4b. Treasury approves the zap on HOLLAR.
  const erc20Iface = new utils.Interface([
    "function approve(address spender, uint256 value) returns (bool)",
  ]);
  const approveCalldata = erc20Iface.encodeFunctionData("approve", [
    zapAddr,
    HOLLAR_DEPOSIT_AMOUNT,
  ]);
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.evm.call(
        treasuryEvm,
        hollarAddr,
        approveCalldata,
        "0",
        "200000",
        "600000000",
        undefined,
        undefined,
        [],
        []
      )
    )
  );

  // 4c. Treasury calls zap.depositAndSupply(300K HOLLAR).
  // Atomic: HOLLAR.transferFrom + vault.deposit + pool.supply.
  const zapIface = new utils.Interface([
    "function depositAndSupply(uint256 hollarAmount)",
  ]);
  const depositCalldata = zapIface.encodeFunctionData("depositAndSupply", [
    HOLLAR_DEPOSIT_AMOUNT,
  ]);
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.evm.call(
        treasuryEvm,
        zapAddr,
        depositCalldata,
        "0",
        "5000000", // zap's atomic call (transferFrom + deposit + supply) is heavy
        "600000000",
        undefined,
        undefined,
        [],
        []
      )
    )
  );

  // 4d. Treasury adds liquidity to the new pool.
  // Asset order: ascending (HDCL=55 first, HOLLAR=222 second).
  // Inverting silently produces wrong pool composition — see handover doc.
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.stableswap.addAssetsLiquidity(
        ...Object.values({
          poolId: POOL_LP,
          assets: [
            { assetId: HDCL, amount: HDCL_SUPPLY_AMOUNT },
            { assetId: HOLLAR, amount: HOLLAR_PAIR_AMOUNT },
          ],
          minShares: 0, // initial liquidity — no slippage protection needed
        })
      )
    )
  );

  // Schedule the bootstrap 1 block after pool creation.
  txs.push(
    hydrationTx.scheduler.scheduleAfter(
      1,
      null,
      0,
      hydrationTx.utility.batchAll(last)
    )
  );

  return txs;
}

/** Read the vault proxy address from HDCLOracleAdapter. */
async function readVaultAddress(hre: any, oracleAdapterAddr: string) {
  const oracle = new hre.ethers.Contract(
    oracleAdapterAddr,
    ["function vault() view returns (address)"],
    hre.ethers.provider
  );
  return await oracle.vault();
}

/**
 * Read the canonical Hydration main-MM Pool-Proxy address from the
 * mainnet deployments folder. Lark inherits the same address via the
 * fork — the artifact isn't replicated in deployments/lark/ because
 * lark only has HDCL-specific deploys.
 */
function readMainHydrationPool(taskDir: string): string {
  const artifactPath = path.join(
    taskDir,
    "../../deployments/hydration/Pool-Proxy-Hydration.json"
  );
  const raw = fs.readFileSync(artifactPath, "utf-8");
  const artifact = JSON.parse(raw);
  if (!artifact.address) {
    throw new Error(
      `Could not read main MM Pool-Proxy address from ${artifactPath}`
    );
  }
  return artifact.address;
}
