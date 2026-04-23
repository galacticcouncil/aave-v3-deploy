// Submit the HDCL governance proposal end-to-end. Defaults to chopsticks
// (ws://localhost:8000) for dry-run; set PROPOSAL_WS=wss://0.lark.hydration.cloud
// to run against the real testnet.
//
// Flow (matches Yash's gigahdx submit script, adapted for HDCL):
//   0. Re-generate the proposal via hdcl task's helpers so objects bind to
//      current runtime metadata.
//   1. Alice (sole TC member) TC-whitelists whitelistedCall.hash.
//   2. Note the proposal preimage.
//   3. Submit a track-1 (whitelisted_caller) referendum.
//   4. Alice places decision deposit + votes aye with full conviction.
//   5. On chopsticks: fast-forward via dev_newBlock. On real chain: poll.
//   6. Scan recent block events for success/failure.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import hre from "hardhat";

const PROPOSAL_WS = process.env.PROPOSAL_WS || "ws://localhost:8000";
const IS_CHOPSTICKS = PROPOSAL_WS.includes("localhost") || PROPOSAL_WS.includes("127.0.0.1");

async function devNewBlock(api: ApiPromise, count = 1) {
  for (let i = 0; i < count; i++) {
    await (api as any)._rpcCore.provider.send("dev_newBlock", [{}]);
  }
}

// On chopsticks: Alice's mainnet-forked state has all her HDX locked behind an
// unrelated conviction-voting lock. Unfreeze her so she can submit + deposit +
// vote on the HDCL referendum here.
async function unfreezeAliceOnChopsticks(api: ApiPromise, alice: any): Promise<void> {
  if (!IS_CHOPSTICKS) return;
  console.log("\n--- unfreezing Alice on chopsticks ---");
  const accountKey = api.query.system.account.key(alice.address);
  const locksKey = api.query.balances.locks.key(alice.address);
  const freezesKey = api.query.balances.freezes.key(alice.address);
  const acc = await api.query.system.account(alice.address);
  const nonce = (acc as any).nonce.toNumber();
  // Keep her free balance but zero out frozen, reserved, and flags.
  const newAccountInfo = api.registry.createType("AccountInfo", {
    nonce,
    consumers: 0,
    providers: 1,
    sufficients: 0,
    data: {
      free: (acc as any).data.free.toBigInt().toString(),
      reserved: "0",
      frozen: "0",
      flags: "0",
    },
  });
  const emptyVec = api.registry.createType("Vec<BalanceLock>", []);
  await (api as any)._rpcCore.provider.send("dev_setStorage", [
    [
      [accountKey, u8aToHex(newAccountInfo.toU8a())],
      [locksKey, u8aToHex(emptyVec.toU8a())],
      [freezesKey, null],
    ],
  ]);
  const bal2: any = await api.query.system.account(alice.address);
  const free = bal2.data.free.toBigInt();
  const frozen = bal2.data.frozen.toBigInt();
  console.log(`  Alice free=${(free/10n**12n).toString()} HDX, frozen=${(frozen/10n**12n).toString()} HDX`);
}

async function signAndWait(
  tx: SubmittableExtrinsic<"promise">,
  signer: any,
  api: ApiPromise,
  label: string
): Promise<any[]> {
  console.log(`\n--- ${label} ---`);
  // Fetch a fresh nonce each time — chopsticks' tx pool doesn't always update
  // between submissions, so relying on cached nonce causes "invalid: stale".
  const nonce = (await api.rpc.system.accountNextIndex(signer.address)) as any;
  return new Promise((resolve, reject) => {
    let unsub: any;
    tx.signAndSend(signer, { nonce }, async ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      const terminal = status.isInBlock || status.isFinalized;
      if (!terminal) return;
      if (dispatchError) {
        if (dispatchError.isModule) {
          const d = api.registry.findMetaError(dispatchError.asModule);
          if (unsub) unsub();
          return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
        }
        if (unsub) unsub();
        return reject(new Error(dispatchError.toString()));
      }
      for (const { event } of events) {
        if (event.section === "system" && event.method === "ExtrinsicFailed") {
          if (unsub) unsub();
          return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
        }
      }
      console.log(`  OK`);
      if (unsub) unsub();
      resolve(events as any[]);
    }).then((u) => { unsub = u; }).catch(reject);
  });
}

async function main() {
  console.log(`Connecting to ${PROPOSAL_WS} (chopsticks=${IS_CHOPSTICKS})`);
  // -------- Regenerate the HDCL proposal (same logic as tasks/proposals/hdcl.ts) --------
  const { generateProposalV2, getApi, location, aaveManagerCall } = await import(
    "../helpers/hydration-proposal.js"
  );
  const { addTransaction, getBatch, clearBatch } = await import(
    "../helpers/transaction-batch"
  );
  const { getPoolAddressesProvider, getPoolConfiguratorProxy, POOL_ADMIN, TREASURY_PROXY_ID, FORK } =
    await import("../helpers");
  const { MARKET_NAME } = await import("../helpers/env");

  const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
  const GHO_ORACLE = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";

  const hhre = hre as any;
  const { utils } = hhre.ethers;
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
  await hhre.run("init-reserve", { symbol: "HDCL", batch: true });
  await hhre.run("review-reserve-factors", { fix: true, batch: true });
  const hdclTxs = await Promise.all(getBatch().map((tx: any) => aaveManagerCall({ ...tx, from: admin })));
  txs.push(...hdclTxs);
  clearBatch();

  // Phase B
  const ghoATokenImpl = await hhre.deployments.get("GhoAToken-HDCL");
  const ghoStableDebtImpl = await hhre.deployments.get("GhoStableDebtToken-HDCL");
  const ghoVariableDebtImpl = await hhre.deployments.get("GhoVariableDebtToken-HDCL");
  const ghoInterestRateStrategy = await hhre.deployments.get("GhoInterestRateStrategy-HDCL");
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

  // Phase C — predict GhoAToken proxy based on whether HDCL is already inited
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hhre.ethers.provider.getTransactionCount(configuratorAddress);

  const HDCL_UNDERLYING = "0x0000000000000000000000000000000100000037";
  const pool = await hhre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16,address aTokenAddress,address,address,address,uint128,uint128,uint128))",
    ],
    await poolAddressesProvider.getPool()
  );
  const reservesList: string[] = await pool.getReservesList();
  const hdclAlreadyInit = reservesList
    .map((a: string) => a.toLowerCase())
    .includes(HDCL_UNDERLYING.toLowerCase());
  const hollarOffset = hdclAlreadyInit ? 0 : 3;

  const hdclATokenAddress: string = hdclAlreadyInit
    ? (await pool.getReserveData(HDCL_UNDERLYING)).aTokenAddress
    : utils.getContractAddress({ from: configuratorAddress, nonce: currentNonce });
  const ghoATokenProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset,
  });
  const ghoVariableDebtProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset + 2,
  });
  console.log(`HDCL already initialized: ${hdclAlreadyInit}`);
  console.log(`HDCL aToken: ${hdclATokenAddress}`);
  console.log(`predicted GhoAToken: ${ghoATokenProxyAddress}`);
  console.log(`predicted GhoVariableDebt: ${ghoVariableDebtProxyAddress}`);

  {
    const hollar = new hhre.ethers.Contract(HOLLAR, (await hhre.deployments.get("HOLLAR")).abi, signer);
    const existing = await (hollar as any).getFacilitator(ghoATokenProxyAddress);
    const existingCap = existing?.bucketCapacity ?? existing?.[0] ?? 0n;
    if (BigInt(existingCap.toString()) > 0n) {
      console.log(`HOLLAR facilitator already added for ${ghoATokenProxyAddress} (cap=${existingCap}) — skipping`);
    } else {
      const bucketCapacity = utils.parseUnits("1.0", 24); // 1M HOLLAR
      const tx = await hollar.populateTransaction.addFacilitator(ghoATokenProxyAddress, "HDCL", bucketCapacity, {
        gasLimit: 500_000,
      });
      addTransaction(tx);
    }
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
  const HDCL_ASSET_ID = 55;
  const AHDCL_ASSET_ID = 550;
  const hdclInfo: any = await apiInst.query.assetRegistry.assets(HDCL_ASSET_ID);
  const aHdclInfo: any = await apiInst.query.assetRegistry.assets(AHDCL_ASSET_ID);

  if (!hdclInfo.isSome) {
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: HDCL_ASSET_ID,
          name: "HDCL",
          assetType: "Token",
          existentialDeposit: "20000000000000000",
          symbol: "HDCL",
          decimals: 18,
          location: null,
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    console.log(`HDCL (${HDCL_ASSET_ID}) already registered — skipping register`);
  }

  if (!aHdclInfo.isSome) {
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: AHDCL_ASSET_ID,
          name: "aHDCL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000",
          symbol: "aHDCL",
          decimals: 18,
          location: location(hdclATokenAddress),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    const locOnChain: any = await apiInst.query.assetRegistry.assetLocations(AHDCL_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = hdclATokenAddress.toLowerCase();
    if (currentKey !== expectedKey) {
      console.log(`aHDCL (${AHDCL_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`);
      txs.push(
        hydrationTx.assetRegistry.update(
          AHDCL_ASSET_ID,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          location(hdclATokenAddress)
        )
      );
    } else {
      console.log(`aHDCL (${AHDCL_ASSET_ID}) already at correct location — skipping`);
    }
  }

  // Phase E — fee-payment currencies (HOLLAR price, 1 HDCL = 1 HOLLAR at launch)
  // Skip already-accepted to avoid reverting whole batchAll on re-submit.
  const HOLLAR_FEE_PRICE = "10960000000000000000000";
  const hdclFee: any = await apiInst.query.multiTransactionPayment.acceptedCurrencies(HDCL_ASSET_ID);
  const aHdclFee: any = await apiInst.query.multiTransactionPayment.acceptedCurrencies(AHDCL_ASSET_ID);
  if (!hdclFee.isSome) {
    txs.push(hydrationTx.multiTransactionPayment.addCurrency(...Object.values({ asset: HDCL_ASSET_ID, price: HOLLAR_FEE_PRICE })));
  } else {
    console.log(`HDCL fee currency already accepted — skipping`);
  }
  if (!aHdclFee.isSome) {
    txs.push(hydrationTx.multiTransactionPayment.addCurrency(...Object.values({ asset: AHDCL_ASSET_ID, price: HOLLAR_FEE_PRICE })));
  } else {
    console.log(`aHDCL fee currency already accepted — skipping`);
  }

  // For lark/chopsticks dry-run: submit the raw batchAll on the Root track.
  // On mainnet this would go through WhitelistedCaller — but on lark
  // the Root track confirms within a block with ~4B HDX conviction-voted aye.
  // Execution logic is identical (WhitelistedCaller ultimately dispatches the
  // batchAll with Root origin), so this tests the same 17 calls.
  const batchAllCall = await generateProposalV2(txs, false);
  console.log(`\nbatchAll.hash:   ${batchAllCall.hash.toHex()}`);
  console.log(`batchAll.length: ${batchAllCall.encodedLength}`);

  await apiInst.disconnect();

  // -------- Submit via fresh api (chopsticks or 0.lark) --------
  const api = await ApiPromise.create({ provider: new WsProvider(PROPOSAL_WS) });
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  const proposalHash = batchAllCall.hash.toHex();
  const proposalHex = batchAllCall.toHex();
  const proposalLen = batchAllCall.encodedLength;

  await unfreezeAliceOnChopsticks(api, alice);

  // 1. Note proposal preimage
  try {
    await signAndWait(api.tx.preimage.notePreimage(proposalHex), alice, api, "preimage.notePreimage(batchAll)");
  } catch (e: any) {
    if (!/AlreadyNoted/i.test(e?.message ?? "")) throw e;
    console.log("Proposal preimage already noted — continuing");
  }

  // 2. Submit referendum on Root track (fast confirm on lark)
  const events = await signAndWait(
    api.tx.referenda.submit(
      { system: "Root" },
      { Lookup: { hash: proposalHash, len: proposalLen } },
      { After: 1 }
    ),
    alice,
    api,
    "referenda.submit(Root track)"
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

  // 4. Deposit + vote aye with full conviction
  await signAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api, "placeDecisionDeposit");
  // 4B HDX — enough to instantly confirm on lark's Root track.
  const voteBalance = (BigInt(4_000_000_000) * BigInt(10 ** 12)).toString();
  await signAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
    }),
    alice,
    api,
    "convictionVoting.vote"
  );

  // 5. Poll / fast-forward
  if (IS_CHOPSTICKS) {
    console.log("\nFast-forwarding blocks on chopsticks until approval + enactment...");
    for (let i = 0; i < 200; i++) {
      await devNewBlock(api, 1);
      const ref: any = await api.query.referenda.referendumInfoFor(refIndex);
      if (ref.isSome) {
        const info = ref.unwrap();
        if (info.isApproved) {
          console.log(`  approved after ~${i} blocks`);
          break;
        }
        if (info.isRejected || info.isCancelled || info.isTimedOut || info.isKilled) {
          throw new Error(`Ref ${refIndex} ${info.type}`);
        }
      }
    }
    console.log("  Building further blocks for enactment...");
    await devNewBlock(api, 30);
  } else {
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
    console.log("Waiting 18s for enactment...");
    await new Promise((r) => setTimeout(r, 18000));
  }

  // 6. Scan recent block events for outcome
  const head = (await api.rpc.chain.getHeader()).number.toNumber();
  console.log(`\n=== scanning events in blocks ${Math.max(0, head - 40)}..${head} ===`);
  for (let b = Math.max(0, head - 40); b <= head; b++) {
    const hash = await api.rpc.chain.getBlockHash(b);
    const apiAt = await api.at(hash);
    const events: any = await apiAt.query.system.events();
    const relevant = events.filter((e: any) =>
      ["scheduler", "whitelist", "dispatcher", "assetRegistry", "evm", "utility", "multiTransactionPayment"].includes(
        e.event.section.toString()
      )
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
