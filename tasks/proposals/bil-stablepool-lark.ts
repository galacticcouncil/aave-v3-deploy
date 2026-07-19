// @ts-nocheck
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
// Used to patch lark-2 (where the main bil.ts proposal already ran without
// the stablepool component) up to parity with what mainnet's main proposal
// will produce. Mainnet doesn't run this — it gets the same bootstrap as
// part of bil.ts (`buildStablepoolTxs` is also imported there).
task(
  `bil-stablepool-patch`,
  `Stablepool delta for BIL — registers 2-Pool-BIL (10055), creates the ` +
    `BIL/HOLLAR stableswap, and bootstraps 300K/300K liquidity from the ` +
    `Treasury's own HOLLAR (topped up 40K from the HOLLAR treasury; no ` +
    `main-MM borrow). Use this when the main bil.ts proposal has already ` +
    `executed on a network and only the stablepool piece is missing (lark-2).`
).setAction(async function (_, hre) {
  const preimage = await buildBilStablepoolProposal(hre);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("\n===== Proposal preimage =====");
  console.log(preimage.toHex());
  console.log("\n===== Decoded proposal calls =====");
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
});

/**
 * Build the BIL stablepool launch proposal preimage. Returns the
 * `extrinsic.method` (a single SubmittableExtrinsic) suitable for passing
 * to `referenda.submit` via a Lookup preimage.
 *
 * Exported so submit scripts can re-build without going through the
 * hardhat task printer.
 */
export async function buildBilStablepoolProposal(hre: any) {
  const txs = await buildStablepoolTxs(hre);
  return await generateProposalV2(txs, false);
}

/**
 * Build the raw tx list for the stablepool bootstrap. Returns
 * SubmittableExtrinsics in batch-order, ready to be concatenated onto any
 * larger `utility.batchAll` (e.g. by `bil.ts` to fold the bootstrap into
 * the main launch proposal).
 *
 * `inline = true` means the caller is `bil.ts` folding this into the main
 * launch batch, so asset 55 (BIL aToken) will be registered earlier in the
 * SAME batch — skip the on-chain "asset 55 registered" precondition. The
 * runtime still validates at execution time inside `batchAll`. The
 * standalone `bil-stablepool-patch` task keeps the check (default false),
 * since it runs against a chain where bil.ts has already enacted.
 *
 * Idempotent at the proposal level: still throws if the stablepool is
 * already live (asset 10055 registered), so callers can catch and skip
 * when running against a network where the bootstrap is done.
 */
export async function buildStablepoolTxs(hre: any, opts: { inline?: boolean } = {}) {
  const inline = opts.inline === true;
  const { utils } = hre.ethers;

  // ====================================================================
  // Configuration
  // ====================================================================

  // Asset IDs (mainnet-aligned naming, used on lark-2 too as of refs #383+):
  //   BIL  (asset 55,  precompile 0x…0037) — aToken receipt; what users hold
  //   uBIL (asset 550, precompile 0x…0226) — unwrapped vault share; the pool's reserve
  //   2-Pool-BIL (asset 10055)            — NEW stableswap LP token
  // The stableswap pair is (BIL aToken ↔ HOLLAR) so a redeem-without-queue
  // path means swapping the aToken receipt directly into HOLLAR.
  const BIL = 55;     // aToken receipt — what users hold
  const HOLLAR = 222;
  const POOL_LP = 10055;

  // Treasury substrate address. Same on lark since lark forks mainnet.
  // Reused from heurc-launch / hollar-pools-launch. Holds ~597K HOLLAR; the
  // bootstrap tops it up by sweeping the main-MM HOLLAR aToken's accrued fees
  // (~44K, see step 3b) so it can fund the full 600K from its own balance.
  const treasury = "7L53bUTBopuwFt3mKUfmkzgGLayYa1Yvn1hAg9v5UMrQzTfh";

  // Main money-market HOLLAR GhoAToken. HOLLAR borrow interest does NOT sit in
  // the Aave Collector (0xE525 holds <1K) — it accrues inside this aToken (~44K)
  // and is only realised by distributeFeesToTreasury(), which pays out to the
  // aToken's configured ghoTreasury. Step 3b taps it to top up the Treasury.
  // ORIG_GHO_TREASURY is its normal fee sink (the Collector), restored right
  // after the sweep — all atomic within this batch.
  const MAIN_GHO_ATOKEN = "0x8C0f3b9602374198974d2B2679d14a386f5b108e";
  const ORIG_GHO_TREASURY = "0xE52567fF06aCd6CBe7BA94dc777a3126e180B6d9";
  const AAVE_MANAGER = "0xaa7e0000000000000000000000000000000aa7e0";

  // Stableswap pool params — see BIL-MAINNET-HANDOVER.md "Mainnet
  // single-batch launch composition" for the rationale on each.
  // 50 (not the peers' 100-222): BIL exits are one-way flow against the
  // treasury LP, so a faster-growing imbalance discount protects it — ~1%
  // marginal discount at 62/38 instead of 71/29 (see amp-curve tables).
  const AMPLIFICATION = 50;
  const FEE = 1000; // 0.1%
  const MAX_PEG_UPDATE = 200; // gigasol-style "≥10× expected APY"

  // Bootstrap amounts. Treasury funds the whole 600K from its OWN HOLLAR (no
  // borrow): 300K is zap-minted into BIL, 300K is paired alongside it into the
  // new stablepool.
  const HOLLAR_DEPOSIT_AMOUNT = utils.parseEther("300000").toString();
  const HOLLAR_PAIR_AMOUNT = utils.parseEther("300000").toString();
  // Top-up is dynamic: step 3b sweeps whatever HOLLAR fees have accrued in the
  // main-MM aToken (~44K) into the Treasury; the balance check below reads the
  // live accrued amount to confirm the bootstrap will be funded.

  // ====================================================================
  // API + deployment lookups
  // ====================================================================
  const hydrationApi = await getApi();
  const hydrationTx = hydrationApi.tx;

  const oracleAdapter = (await hre.deployments.get("BILOracleAdapter"))
    .address;
  const zapAddr = (await hre.deployments.get("BILDepositZap")).address;
  const hollarAddr = (await hre.deployments.get("HOLLAR")).address;

  console.log("BILOracleAdapter:    ", oracleAdapter);
  console.log("BILDepositZap:       ", zapAddr);
  console.log("HOLLAR:               ", hollarAddr);

  // ====================================================================
  // Pre-flight checks — fail fast if state isn't right
  // ====================================================================

  const lpInfo: any =
    await hydrationApi.query.assetRegistry.assets(POOL_LP);
  if (lpInfo.isSome) {
    throw new Error(
      `Asset ${POOL_LP} (2-Pool-BIL) is already registered. ` +
        `This proposal is single-shot — skip if the stablepool is already live.`
    );
  }

  if (!inline) {
    const bilInfo: any = await hydrationApi.query.assetRegistry.assets(BIL);
    if (!bilInfo.isSome) {
      throw new Error(
        `Asset ${BIL} (BIL aToken receipt) is not registered. The bil.ts ` +
          `proposal must execute first (or pass { inline: true } to fold ` +
          `into the same batch).`
      );
    }
  }

  // BILDepositZap must be max-approved on HOLLAR→Vault.
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
      `BILDepositZap's HOLLAR→Vault allowance (${zapHollarAllowance}) is ` +
        `below the deposit amount (${HOLLAR_DEPOSIT_AMOUNT}). The zap should ` +
        `have been deployed with a max-approve to the vault — verify the deploy.`
    );
  }

  // Treasury funds the bootstrap from its OWN HOLLAR (no main-MM borrow), after
  // step 3b sweeps the main-MM aToken's accrued HOLLAR fees into it. Validate
  // that (Treasury balance + accrued aToken fees) covers the 600K need.
  const treasuryEvm = await evmAddress(treasury);
  // HOLLAR (asset 222) is an Erc20-type asset — its balance lives in the ERC20
  // contract (asset 222's location IS 0x531a…), NOT in tokens.accounts, which
  // reads 0. Read balanceOf, which is what the zap and the stableswap Erc20 leg
  // actually pull from (and where distributeFeesToTreasury credits the sweep).
  const hollarErc20 = new hre.ethers.Contract(
    hollarAddr,
    ["function balanceOf(address) view returns (uint256)"],
    hre.ethers.provider
  );
  const treasuryHollar = (await hollarErc20.balanceOf(treasuryEvm)).toBigInt();
  const aTokenAccrued = (await hollarErc20.balanceOf(MAIN_GHO_ATOKEN)).toBigInt();
  const bootstrapNeed = BigInt(HOLLAR_DEPOSIT_AMOUNT) + BigInt(HOLLAR_PAIR_AMOUNT);
  const afterTopUp = treasuryHollar + aTokenAccrued;
  if (afterTopUp < bootstrapNeed) {
    console.warn(
      `\n!!! WARNING: Treasury HOLLAR ${treasuryHollar} + aToken fees ${aTokenAccrued} ` +
        `= ${afterTopUp} < bootstrap need ${bootstrapNeed}.\n    The zap/pair steps ` +
        `will revert. Fund the Treasury or shrink the seed before submitting.\n`
    );
  } else {
    console.log(
      `Treasury HOLLAR ${treasuryHollar} + aToken fees ${aTokenAccrued} = ` +
        `${afterTopUp} (need ${bootstrapNeed}) OK`
    );
  }

  // ====================================================================
  // Predict BIL mint amount from a 300K HOLLAR deposit
  // ====================================================================
  // The zap mints BIL aToken at vault.exchangeRate at execution time.
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
  const expectedBil =
    (BigInt(HOLLAR_DEPOSIT_AMOUNT) * ONE_WAD) / exchangeRateWad;
  // Under-promise by 0.3% (≈ 7 days of 18% APY yield, minus a little).
  const BIL_SUPPLY_AMOUNT = ((expectedBil * 997n) / 1000n).toString();
  console.log(
    `vault.exchangeRate at build: ${exchangeRateWad}; expected mint: ${expectedBil}; ` +
      `safe-supply (0.3% buffer): ${BIL_SUPPLY_AMOUNT}`
  );

  // ====================================================================
  // 2-Pool-BIL fee-currency price — reuse HOLLAR's price
  // ====================================================================
  // 1 LP share ≈ 1 HOLLAR at launch (pool bootstrapped 50/50 around 1:1 peg).
  const hollarFee: any =
    await hydrationApi.query.multiTransactionPayment.acceptedCurrencies(
      HOLLAR
    );
  if (!hollarFee.isSome) {
    throw new Error(
      `HOLLAR (${HOLLAR}) is not a registered fee currency. Cannot derive ` +
        `2-Pool-BIL fee price.`
    );
  }
  const HOLLAR_FEE_PRICE = hollarFee.unwrap().toString();
  console.log("HOLLAR fee price (reused for 2-Pool-BIL):", HOLLAR_FEE_PRICE);

  // ====================================================================
  // Resolve BIL pool's AaveOracle (for the consolidation step below)
  // ====================================================================
  const bilAaveOracleAddr = (
    await hre.deployments.get("AaveOracle-BIL")
  ).address;
  // The BIL pool's reserve is BIL (asset 550 → precompile 0x…0226).
  // setAssetSources is keyed by the reserve underlying address.
  const DCL_PRECOMPILE = "0x0000000000000000000000000000000100000226";
  console.log("BIL AaveOracle:      ", bilAaveOracleAddr);

  // ====================================================================
  // Build proposal
  // ====================================================================
  const txs: any[] = [];
  const last: any[] = [];

  // -------- 0. Consolidate BIL pool's oracle to the new (V3-compliant) oracle --------
  // The original BILOracleAdapter only implemented the legacy IEACAggregatorProxy
  // (latestAnswer). Hydration's stableswap pallet's MMOracle peg-source resolver
  // calls latestRoundData() (Chainlink V3), so we re-deployed BILOracleAdapter
  // with the full V3 interface. Both Aave and stableswap should now use the new
  // oracle so there's only one source of truth on lark.
  //
  // Encoded as `dispatcher.dispatchAsAaveManager(evm.call(setAssetSources, ...))`
  // — same admin-EVM pattern bil.ts uses for its other Aave Manager calls.
  // Idempotent: setAssetSources is a plain assignment, safe to re-run.
  console.log(
    `---------> consolidate BIL AaveOracle source for ${DCL_PRECOMPILE} → ${oracleAdapter}`
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
        to: bilAaveOracleAddr,
        data: setSourcesData,
        gasLimit: "300000",
      })
    );
  }

  // -------- 1. Register 2-Pool-BIL (10055) --------
  console.log("---------> register 2-Pool-BIL (10055)");
  txs.push(
    hydrationTx.assetRegistry.register(
      ...Object.values({
        id: POOL_LP,
        name: "2-Pool-BIL",
        assetType: "StableSwap",
        existentialDeposit: "17241379310344828",
        symbol: "2-Pool-BIL",
        decimals: 18,
        location: null,
        xcmRateLimit: utils.parseEther("1500000").toString(),
        isSufficient: true,
      })
    )
  );

  // -------- 2. Allow 2-Pool-BIL as fee currency --------
  console.log("---------> add 2-Pool-BIL as fee currency");
  txs.push(
    hydrationTx.multiTransactionPayment.addCurrency(
      ...Object.values({ asset: POOL_LP, price: HOLLAR_FEE_PRICE })
    )
  );

  // -------- 3. Create stableswap pool (BIL ↔ HOLLAR) --------
  // Assets sorted ascending: BIL(55) < HOLLAR(222). Sort order matters —
  // the runtime enforces it and the peg-source array follows the same order.
  // Peg sources:
  //   BIL   (sorted first):  MMOracle = BILOracleAdapter, which reads
  //                           vault.exchangeRate() scaled to 8 dec. The
  //                           aToken is 1:1 redeemable for the underlying
  //                           (Aave V3 scaledBalance × liquidityIndex), so
  //                           1 BIL = vault.exchangeRate() HOLLAR. Same
  //                           oracle the Aave reserve uses.
  //   HOLLAR (sorted second): fixed 1:1 base reference.
  // maxPegUpdate=200 follows gigasol's ≥10× APY rule for BIL's ~18% APY.
  console.log("---------> create stableswap pool (BIL ↔ HOLLAR)");
  txs.push(
    hydrationTx.stableswap.createPoolWithPegs(
      ...Object.values({
        shareAsset: POOL_LP,
        assets: [BIL, HOLLAR],
        amplification: AMPLIFICATION,
        fee: FEE,
        pegSource: [
          { MMOracle: oracleAdapter }, // BIL (sorted first)
          { value: [1, 1] }, // HOLLAR (sorted second) — fixed 1:1 base
        ],
        maxPegUpdate: MAX_PEG_UPDATE,
      })
    )
  );

  // -------- 3a. Router routes for fee conversion (BIL aToken ↔ HDX/WETH) --------
  // Without these, multiTransactionPayment.addCurrency(55) accepts BIL as a
  // fee asset but the runtime can't actually swap to gas. Convention (3pool,
  // heurc, hollar-pools): register only HDX→target and WETH→target; the
  // runtime invokes the stored route in the direction it needs.
  //
  // Routes terminate at asset 55 (the aToken — what users hold). We don't
  // register routes terminating at asset 550 (the vault underlying) because
  // that would require an `{pool: Aave, assetIn: 55, assetOut: 550}` hop and
  // Hydration's router-Aave integration currently binds to exactly one money
  // market (the main MM, not BIL).
  //
  // Path topology:
  //   HDX (0)   → HOLLAR (222) : existing Omnipool route
  //   WETH (20) → HOLLAR (222) : existing 5-hop route
  //   HOLLAR (222) → BIL (55)  : NEW Stableswap POOL_LP (10055), this proposal
  const HDX = 0;
  const WETH = 20;
  const hopHdxToHollar = { pool: "Omnipool", assetIn: HDX, assetOut: HOLLAR };
  const hopWethToHollar = [
    { pool: { Stableswap: 104 }, assetIn: WETH, assetOut: 1007 },
    { pool: { Stableswap: 4200 }, assetIn: 1007, assetOut: 4200 },
    { pool: "Aave", assetIn: 4200, assetOut: 420 },
    { pool: "Omnipool", assetIn: 420, assetOut: HOLLAR },
  ];
  const hopHollarToBil = { pool: { Stableswap: POOL_LP }, assetIn: HOLLAR, assetOut: BIL };

  console.log("---------> insert router routes for BIL ↔ HDX/WETH fee conversion");
  for (const [pair, route, label] of [
    [{ assetIn: HDX, assetOut: BIL }, [hopHdxToHollar, hopHollarToBil], "HDX→BIL"],
    [{ assetIn: WETH, assetOut: BIL }, [...hopWethToHollar, hopHollarToBil], "WETH→BIL"],
  ]) {
    console.log(`         + ${label} (${route.length} hops)`);
    txs.push(hydrationTx.router.forceInsertRoute(pair, route));
  }

  // -------- 3b. Top the Treasury up by sweeping the main-MM aToken fees -------
  // Runs immediately with the proposal (main `txs`, not the scheduled batch) so
  // the funds land in the Treasury before the +1-block bootstrap needs them.
  //
  // HOLLAR borrow interest is NOT held by the Collector (0xE525, <1K) — it
  // accrues inside the main GhoAToken (~44K) and is only realised by
  // distributeFeesToTreasury(), which pays the aToken's configured ghoTreasury.
  // So, atomically within this batch:
  //   (i)   repoint the aToken's ghoTreasury to the bootstrap Treasury,
  //   (ii)  distributeFeesToTreasury() -> sweeps accrued HOLLAR to the Treasury,
  //   (iii) restore the original ghoTreasury (the Collector).
  // updateGhoTreasury is onlyPoolAdmin on the main pool (the aave-manager holds
  // that role and is NOT the aToken's proxy admin, so no transparent-proxy wall);
  // distributeFeesToTreasury is permissionless. Recipient is the Treasury's bound
  // EVM address; the HOLLAR ERC20 credits the same 7L53 balance the bootstrap's
  // addAssetsLiquidity reads.
  console.log(
    `---------> sweep main-MM aToken ${MAIN_GHO_ATOKEN} HOLLAR fees -> Treasury (${treasuryEvm})`
  );
  {
    const atokenIface = new utils.Interface([
      "function updateGhoTreasury(address newGhoTreasury)",
      "function distributeFeesToTreasury()",
    ]);
    // (i) redirect the aToken's fee sink to the Treasury
    txs.push(
      await aaveManagerCall({
        from: AAVE_MANAGER,
        to: MAIN_GHO_ATOKEN,
        data: atokenIface.encodeFunctionData("updateGhoTreasury", [treasuryEvm]),
        gasLimit: "300000",
      })
    );
    // (ii) sweep accrued HOLLAR fees to the Treasury
    txs.push(
      await aaveManagerCall({
        from: AAVE_MANAGER,
        to: MAIN_GHO_ATOKEN,
        data: atokenIface.encodeFunctionData("distributeFeesToTreasury", []),
        gasLimit: "400000",
      })
    );
    // (iii) restore the original fee sink (the Collector)
    txs.push(
      await aaveManagerCall({
        from: AAVE_MANAGER,
        to: MAIN_GHO_ATOKEN,
        data: atokenIface.encodeFunctionData("updateGhoTreasury", [ORIG_GHO_TREASURY]),
        gasLimit: "300000",
      })
    );
  }

  // -------- 4. Treasury bootstrap (scheduled +1 block) --------
  // Pool must exist before liquidity flows, so the bootstrap is scheduled
  // 1 block after the proposal's pool-creation step. The Treasury funds the
  // full 600K from its OWN HOLLAR balance (topped up by step 3b) — no main-MM
  // borrow.
  //
  // Steps (all dispatched as Treasury):
  //   4a. EVM:       HOLLAR.approve(zap, 300K)
  //   4b. EVM:       zap.depositAndSupply(300K HOLLAR) → mints ~300K BIL aToken atomically
  //   4c. Substrate: stableswap.addAssetsLiquidity([BIL: BIL_SUPPLY_AMOUNT, HOLLAR: 300K])
  //
  // Treasury's bound EVM address is derived from its substrate AccountId
  // (default truncation). pallet_evm's source-validation requires the
  // dispatcher's bound address to match the EVM call's `source` field.

  console.log("Treasury bound EVM address:", treasuryEvm);

  // 4a. Treasury approves the zap on HOLLAR.
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

  // 4b. Treasury calls zap.depositAndSupply(300K HOLLAR).
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

  // 4c. Treasury adds liquidity to the new pool.
  // Asset order: ascending (BIL=55 first, HOLLAR=222 second).
  // Inverting silently produces wrong pool composition — see handover doc.
  last.push(
    await dispatchAs(
      treasury,
      hydrationTx.stableswap.addAssetsLiquidity(
        ...Object.values({
          poolId: POOL_LP,
          assets: [
            { assetId: BIL, amount: BIL_SUPPLY_AMOUNT },
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

/** Read the vault proxy address from BILOracleAdapter. */
async function readVaultAddress(hre: any, oracleAdapterAddr: string) {
  const oracle = new hre.ethers.Contract(
    oracleAdapterAddr,
    ["function vault() view returns (address)"],
    hre.ethers.provider
  );
  return await oracle.vault();
}
