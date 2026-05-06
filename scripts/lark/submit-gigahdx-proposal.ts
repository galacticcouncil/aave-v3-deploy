// Submit the GIGAHDX governance proposal to lark 1 end-to-end.
//
// Flow:
//   0. Re-generate the proposal via the existing helper so we get fresh
//      { whitelistedCall, proposal } objects tied to the live runtime metadata.
//   1. Alice (sole TC member) TC-whitelists `whitelistedCall.hash`.
//   2. Note the `proposal` preimage (the dispatchWhitelistedCallWithPreimage call).
//   3. Submit a track-1 (whitelisted_caller) referendum with that preimage.
//   4. Alice places decision deposit + votes aye with full conviction (70% of issuance).
//   5. On approval + 1-block confirm + 1-block enactment, the batchAll executes
//      with Root origin, which cascades through dispatcher.dispatchAsAaveManager
//      for the 13 calls.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import hre from "hardhat";

const LARK_WS = "wss://2.lark.hydration.cloud";

async function signAndWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
          }
          return reject(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
          }
        }
        console.log(`  OK`);
        resolve(events as any[]);
      }
    }).catch(reject);
  });
}

async function main() {
  // Regenerate the proposal using the existing gigahdx task's helper flow.
  // This guarantees the preimage matches the CURRENT runtime metadata.
  console.log("Regenerating GIGAHDX proposal to capture whitelistedCall & proposal objects...");
  const { generateProposalV2, getApi, location, aaveManagerCall } = await import(
    "../../helpers/hydration-proposal.js"
  );
  const { addTransaction, getBatch, clearBatch } = await import(
    "../../helpers/transaction-batch"
  );
  const { getPoolAddressesProvider, getPoolConfiguratorProxy, POOL_ADMIN, TREASURY_PROXY_ID, FORK } =
    await import("../../helpers");
  const { MARKET_NAME } = await import("../../helpers/env");

  const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
  const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";

  const hhre = hre as any;
  const { utils, ethers } = hhre.ethers;
  const networkId = FORK ? FORK : hhre.network.name;
  const admin = POOL_ADMIN[networkId];
  const poolAddressesProvider = await getPoolAddressesProvider();
  const poolConfigurator = await getPoolConfiguratorProxy();
  const apiInst = await getApi();
  const hydrationTx = apiInst.tx;
  const { deployer } = await hhre.getNamedAccounts();
  const signer = await hhre.ethers.getSigner(deployer);

  const txs: any[] = [];

  // Phase A
  await hhre.run("init-reserve", { symbol: "STHDX", batch: true });
  await hhre.run("review-reserve-factors", { fix: true, batch: true });
  const sthdxTxs = await Promise.all(getBatch().map((tx: any) => aaveManagerCall({ ...tx, from: admin })));
  txs.push(...sthdxTxs);
  clearBatch();

  // Phase B
  const ghoATokenImpl = await hhre.deployments.get("GhoAToken-GIGAHDX");
  const ghoStableDebtImpl = await hhre.deployments.get("GhoStableDebtToken-GIGAHDX");
  const ghoVariableDebtImpl = await hhre.deployments.get("GhoVariableDebtToken-GIGAHDX");
  const ghoInterestRateStrategy = await hhre.deployments.get("GhoInterestRateStrategy-GIGAHDX");
  const treasuryAddress = (await hhre.deployments.get(TREASURY_PROXY_ID)).address;
  const incentivesController = (await hhre.deployments.get("IncentivesProxy")).address;

  {
    const tx = await poolConfigurator.populateTransaction.initReserves(
      [
        {
          aTokenImpl: ghoATokenImpl.address,
          stableDebtTokenImpl: ghoStableDebtImpl.address,
          variableDebtTokenImpl: ghoVariableDebtImpl.address,
          underlyingAssetDecimals: 18,
          interestRateStrategyAddress: ghoInterestRateStrategy.address,
          underlyingAsset: HOLLAR,
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
  {
    const tx = await poolConfigurator.populateTransaction.setReserveBorrowing(HOLLAR, true, { gasLimit: 1_000_000 });
    addTransaction(tx);
  }
  {
    const oracleArtifact = await hhre.deployments.get(`AaveOracle-${MARKET_NAME}`);
    const oracle = await hhre.ethers.getContractAt(oracleArtifact.abi, oracleArtifact.address);
    const tx = await oracle.populateTransaction.setAssetSources([HOLLAR], [GHO_ORACLE]);
    addTransaction(tx);
  }

  // Phase C — predict GhoAToken proxy based on whether stHDX is already init
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hhre.ethers.provider.getTransactionCount(configuratorAddress);

  const STHDX_UNDERLYING = "0x000000000000000000000000000000010000029e";
  const pool = await hhre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16,address aTokenAddress,address,address,address,uint128,uint128,uint128))",
    ],
    await poolAddressesProvider.getPool()
  );
  const reservesList: string[] = await pool.getReservesList();
  const sthdxAlreadyInit = reservesList
    .map((a: string) => a.toLowerCase())
    .includes(STHDX_UNDERLYING.toLowerCase());
  const hollarOffset = sthdxAlreadyInit ? 0 : 3;

  const sthdxATokenAddress: string = sthdxAlreadyInit
    ? (await pool.getReserveData(STHDX_UNDERLYING)).aTokenAddress
    : utils.getContractAddress({ from: configuratorAddress, nonce: currentNonce });
  const ghoATokenProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset,
  });
  const ghoVariableDebtProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset + 2,
  });
  console.log(`stHDX already initialized: ${sthdxAlreadyInit}`);
  console.log(`stHDX aToken: ${sthdxATokenAddress}`);
  console.log(`predicted GhoAToken: ${ghoATokenProxyAddress}`);
  console.log(`predicted GhoVariableDebt: ${ghoVariableDebtProxyAddress}`);

  {
    const hollar = new hhre.ethers.Contract(HOLLAR, (await hhre.deployments.get("HOLLAR")).abi, signer);
    const bucketCapacity = utils.parseUnits("1.0", 24);
    const tx = await hollar.populateTransaction.addFacilitator(ghoATokenProxyAddress, "GIGAHDX", bucketCapacity, {
      gasLimit: 500_000,
    });
    addTransaction(tx);
  }
  {
    const ghoAToken = new hhre.ethers.Contract(ghoATokenProxyAddress, ghoATokenImpl.abi, signer);
    addTransaction(await ghoAToken.populateTransaction.setVariableDebtToken(ghoVariableDebtProxyAddress));
    addTransaction(await ghoAToken.populateTransaction.updateGhoTreasury(treasuryAddress));
  }
  {
    const ghoVariableDebt = new hhre.ethers.Contract(ghoVariableDebtProxyAddress, ghoVariableDebtImpl.abi, signer);
    addTransaction(await ghoVariableDebt.populateTransaction.setAToken(ghoATokenProxyAddress));
    const zeroDiscountStrategy = await hhre.deployments.get("ZeroDiscountRateStrategy");
    addTransaction(await ghoVariableDebt.populateTransaction.updateDiscountRateStrategy(zeroDiscountStrategy.address));
    addTransaction(await ghoVariableDebt.populateTransaction.updateDiscountToken(HOLLAR));
  }

  const hollarTxs = await Promise.all(getBatch().map((tx: any) => aaveManagerCall({ ...tx, from: admin })));
  txs.push(...hollarTxs);
  clearBatch();

  // Phase D — asset registry (conditional)
  const STHDX = 670;
  const GIGAHDX = 67;
  const sthdxInfo: any = await apiInst.query.assetRegistry.assets(STHDX);
  const gigaInfo: any = await apiInst.query.assetRegistry.assets(GIGAHDX);

  if (!sthdxInfo.isSome) {
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: STHDX,
          name: "stHDX",
          assetType: "Token",
          existentialDeposit: "3000000000000",
          symbol: "stHDX",
          decimals: 12,
          location: null,
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    console.log("stHDX (670) already registered — skipping register");
  }

  if (!gigaInfo.isSome) {
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
    const locOnChain: any = await apiInst.query.assetRegistry.assetLocations(GIGAHDX);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = sthdxATokenAddress.toLowerCase();
    if (currentKey !== expectedKey) {
      console.log(`GIGAHDX (67) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`);
      txs.push(
        hydrationTx.assetRegistry.update(
          GIGAHDX,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          location(sthdxATokenAddress)
        )
      );
    } else {
      console.log("GIGAHDX (67) already at correct location — skipping");
    }
  }

  // Generate whitelisted proposal objects
  const { whitelistedCall, proposal } = await generateProposalV2(txs, true);
  console.log(`\nwhitelistedCall.hash: ${whitelistedCall.hash.toHex()}`);
  console.log(`proposal.hash:        ${proposal.hash.toHex()}`);
  console.log(`proposal.length:      ${proposal.encodedLength}`);

  // Disconnect the hardhat-helper's api (we need a fresh one for signing)
  await apiInst.disconnect();

  // ──────────────────────────────────────────────────────────────
  // Now submit via a fresh api connection with Alice as signer
  // ──────────────────────────────────────────────────────────────
  const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  const innerHash = whitelistedCall.hash.toHex();
  const proposalHash = proposal.hash.toHex();
  const proposalHex = proposal.toHex();
  const proposalLen = proposal.encodedLength;

  // 1. TC whitelist
  const wlEntry: any = await api.query.whitelist.whitelistedCall(innerHash);
  if (!wlEntry.isSome) {
    const whitelistCall = api.tx.whitelist.whitelistCall(innerHash);
    await signAndWait(
      api.tx.technicalCommittee.propose(1, whitelistCall, whitelistCall.method.encodedLength),
      alice,
      api,
      "TC propose(whitelist.whitelistCall)"
    );
  } else {
    console.log("Inner call already whitelisted");
  }

  // 2. Note proposal preimage
  const preStat: any = await api.query.preimage.statusFor(proposalHash);
  if (!preStat.isSome) {
    await signAndWait(api.tx.preimage.notePreimage(proposalHex), alice, api, "preimage.notePreimage(proposal)");
  } else {
    console.log("Proposal preimage already noted");
  }

  // 3. Submit referendum on track 1
  const events = await signAndWait(
    api.tx.referenda.submit(
      { Origins: "WhitelistedCaller" },
      { Lookup: { hash: proposalHash, len: proposalLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit"
  );
  let refIndex: number | null = null;
  for (const { event } of events) {
    if (event.section === "referenda" && event.method === "Submitted") {
      refIndex = (event.data[0] as any).toNumber();
      break;
    }
  }
  if (refIndex == null) throw new Error("no refIndex");
  console.log(`Referendum: ${refIndex}`);

  // 4. Deposit + vote (capped at 4B per Ben's rule — 62% support is well over
  // any track's approval threshold on Hydration and avoids locking more than
  // necessary of Alice's balance).
  await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api, "placeDecisionDeposit");
  const bal: any = await api.query.system.account(alice.address);
  const MAX_VOTE_BASE = 4_000_000_000n * 10n ** 12n;
  const buffered = bal.data.free.toBigInt() - 1_000_000n * 10n ** 12n;
  const voteBalance = (buffered < MAX_VOTE_BASE ? buffered : MAX_VOTE_BASE).toString();
  console.log(`voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX (4B cap)`);
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote"
  );

  // 5. Poll
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 3000));
    const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
    if (!ref.isSome) continue;
    const info = ref.unwrap();
    console.log(`[${i}] ${info.type}`);
    if (info.isApproved) break;
    if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
      throw new Error(`Ref ${refIndex} ${info.type}`);
    }
  }

  console.log("\nWaiting 18s for enactment...");
  await new Promise((r) => setTimeout(r, 18000));

  // 6. Verify outcome by scanning events in the last 15 blocks
  const head = (await api.rpc.chain.getHeader()).number.toNumber();
  console.log(`\n=== scanning events in blocks ${head - 15}..${head} ===`);
  for (let b = head - 15; b <= head; b++) {
    const hash = await api.rpc.chain.getBlockHash(b);
    const apiAt = await api.at(hash);
    const events: any = await apiAt.query.system.events();
    const relevant = events.filter((e: any) =>
      ["scheduler", "whitelist", "dispatcher", "assetRegistry", "evm", "utility"].includes(e.event.section.toString())
    );
    for (const e of relevant) {
      const ev = e.event;
      const data = JSON.stringify(ev.data.toHuman()).slice(0, 250);
      console.log(`  [${b}] ${ev.section}.${ev.method}: ${data}`);
    }
  }

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
