// Submit the BIL governance proposal end-to-end. Defaults to chopsticks
// (ws://localhost:8000) for dry-run; set PROPOSAL_WS=wss://0.lark.hydration.cloud
// to run against the real testnet.
//
// Flow (matches Yash's gigahdx submit script, adapted for BIL):
//   0. Re-generate the proposal via bil task's helpers so objects bind to
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

// On chopsticks: flip block-build mode to Instant so each tx auto-seals a block.
// Default (Manual) makes signAndWait deadlock on isInBlock — and starting
// chopsticks itself in Instant fails ("Failed to apply inherents" on the
// startup-block build). Runtime RPC sidesteps both.
async function setInstantBlockModeOnChopsticks(api: ApiPromise): Promise<void> {
  if (!IS_CHOPSTICKS) return;
  await (api as any)._rpcCore.provider.send("dev_setBlockBuildMode", ["Instant"]);
  console.log("chopsticks: block-build mode → Instant");
}

// On chopsticks: Alice's mainnet-forked state has all her HDX locked behind an
// unrelated conviction-voting lock. Unfreeze her so she can submit + deposit +
// vote on the BIL referendum here. Also bump her free balance well past the
// 4B-HDX Root-vote threshold, since gc chopsticks' default import-storage
// overwrites her to ~1000 HDX.
async function unfreezeAliceOnChopsticks(api: ApiPromise, alice: any): Promise<void> {
  if (!IS_CHOPSTICKS) return;
  console.log("\n--- unfreezing Alice on chopsticks ---");
  const accountKey = api.query.system.account.key(alice.address);
  const locksKey = api.query.balances.locks.key(alice.address);
  const freezesKey = api.query.balances.freezes.key(alice.address);
  const acc = await api.query.system.account(alice.address);
  const nonce = (acc as any).nonce.toNumber();
  // Take max(current, 5B HDX) so she can vote on the Root track. Real-fork
  // Alice has ~4.28B; gc's hydradx.yml import-storage clobbers her to 1000 HDX.
  const HDX_MIN_FREE = 5_000_000_000n * 10n ** 12n; // 5B HDX (12 decimals)
  const currentFree = (acc as any).data.free.toBigInt() as bigint;
  const targetFree = currentFree > HDX_MIN_FREE ? currentFree : HDX_MIN_FREE;
  const newAccountInfo = api.registry.createType("AccountInfo", {
    nonce,
    consumers: 0,
    providers: 1,
    sufficients: 0,
    data: {
      free: targetFree.toString(),
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
  // -------- Regenerate the BIL proposal (same logic as tasks/proposals/bil.ts) --------
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

  // Phase A — BIL collateral reserve init (BIL is the substrate-registered name
  // for the vault token — see Phase D for the registry wiring).
  await hhre.run("init-reserve", { symbol: "BIL", batch: true });
  await hhre.run("review-reserve-factors", { fix: true, batch: true });

  // Register BIL provider into the shared PoolAddressesProviderRegistry. The
  // registry is owned by the aave-manager precompile, so the deploy step
  // deferred this to governance — wrapped here in the Phase A aaveManagerCall
  // batch. Idempotent: skip if already registered (registry reverts on
  // duplicate id, which would silently fail as ExecutedFailed).
  {
    const BIL_PROVIDER_ID = 22222255;
    const registryArtifact = await hhre.deployments.get(
      "PoolAddressesProviderRegistry"
    );
    const registry = await hhre.ethers.getContractAt(
      registryArtifact.abi,
      registryArtifact.address
    );
    const existingId = await registry.getAddressesProviderIdByAddress(
      poolAddressesProvider.address
    );
    if (existingId.gt(0)) {
      console.log(
        `BIL provider ${poolAddressesProvider.address} already in registry (id=${existingId.toString()}) — skipping`
      );
    } else {
      console.log(
        `register BIL provider ${poolAddressesProvider.address} into registry ${registryArtifact.address} (id ${BIL_PROVIDER_ID})`
      );
      addTransaction(
        await registry.populateTransaction.registerAddressesProvider(
          poolAddressesProvider.address,
          BIL_PROVIDER_ID,
          { gasLimit: 1_000_000 }
        )
      );
    }
  }

  const dclTxs = await Promise.all(getBatch().map((tx: any) => aaveManagerCall({ ...tx, from: admin })));
  txs.push(...dclTxs);
  clearBatch();

  // Phase B
  const ghoATokenImpl = await hhre.deployments.get("GhoAToken-BIL");
  const ghoStableDebtImpl = await hhre.deployments.get("GhoStableDebtToken-BIL");
  const ghoVariableDebtImpl = await hhre.deployments.get("GhoVariableDebtToken-BIL");
  const ghoInterestRateStrategy = await hhre.deployments.get("GhoInterestRateStrategy-BIL");
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

  // Phase C — predict GhoAToken proxy based on whether BIL is already inited
  const configuratorAddress = poolConfigurator.address;
  const currentNonce = await hhre.ethers.provider.getTransactionCount(configuratorAddress);

  const DCL_UNDERLYING = "0x0000000000000000000000000000000100000226"; // tokenAddress(550)
  const pool = await hhre.ethers.getContractAt(
    [
      "function getReservesList() view returns (address[])",
      "function getReserveData(address asset) view returns (tuple(tuple(uint256 data) configuration, uint128,uint128,uint128,uint128,uint128,uint40,uint16,address aTokenAddress,address,address,address,uint128,uint128,uint128))",
    ],
    await poolAddressesProvider.getPool()
  );
  const reservesList: string[] = await pool.getReservesList();
  const dclAlreadyInit = reservesList
    .map((a: string) => a.toLowerCase())
    .includes(DCL_UNDERLYING.toLowerCase());
  const hollarOffset = dclAlreadyInit ? 0 : 3;

  const bilATokenAddress: string = dclAlreadyInit
    ? (await pool.getReserveData(DCL_UNDERLYING)).aTokenAddress
    : utils.getContractAddress({ from: configuratorAddress, nonce: currentNonce });
  const ghoATokenProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset,
  });
  const ghoVariableDebtProxyAddress = utils.getContractAddress({
    from: configuratorAddress,
    nonce: currentNonce + hollarOffset + 2,
  });
  console.log(`BIL already initialized: ${dclAlreadyInit}`);
  console.log(`BIL aToken: ${bilATokenAddress}`);
  console.log(`predicted GhoAToken: ${ghoATokenProxyAddress}`);
  console.log(`predicted GhoVariableDebt: ${ghoVariableDebtProxyAddress}`);

  {
    const hollar = new hhre.ethers.Contract(HOLLAR, (await hhre.deployments.get("HOLLAR")).abi, signer);
    const existing = await (hollar as any).getFacilitator(ghoATokenProxyAddress);
    const existingCap = existing?.bucketCapacity ?? existing?.[0] ?? BigInt(0);
    if (BigInt(existingCap.toString()) > BigInt(0)) {
      console.log(`HOLLAR facilitator already added for ${ghoATokenProxyAddress} (cap=${existingCap}) — skipping`);
    } else {
      const bucketCapacity = utils.parseUnits("1.0", 24); // 1M HOLLAR
      const tx = await hollar.populateTransaction.addFacilitator(ghoATokenProxyAddress, "BIL", bucketCapacity, {
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

  // Phase D — asset registry + fee currencies + approve MM contract.
  // Asset id allocation:
  //   55  = BIL  → user-facing aToken (location: BIL aToken proxy)
  //   550 = BIL   → underlying vault token (location: vault proxy)
  const BIL_ATOKEN_ASSET_ID = 55;
  const DCL_ASSET_ID = 550;
  const bilATokenInfo: any = await apiInst.query.assetRegistry.assets(BIL_ATOKEN_ASSET_ID);
  const dclInfo: any = await apiInst.query.assetRegistry.assets(DCL_ASSET_ID);

  // Read vault proxy from the deployed BILOracleAdapter (works on any net).
  const adapterArtifact = await hhre.deployments.get("BILOracleAdapter");
  const adapter = await hhre.ethers.getContractAt(["function vault() view returns (address)"], adapterArtifact.address);
  const BIL_VAULT_PROXY: string = await adapter.vault();
  console.log(`Vault proxy (BIL → asset 550 location): ${BIL_VAULT_PROXY}`);
  console.log(`BIL aToken (BIL → asset 55 location):  ${bilATokenAddress}`);

  // ---- BIL (asset 550): underlying vault → register or update location ----
  if (!dclInfo.isSome) {
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: DCL_ASSET_ID,
          name: "BIL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000",
          symbol: "BIL",
          decimals: 18,
          location: location(BIL_VAULT_PROXY),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    const locOnChain: any = await apiInst.query.assetRegistry.assetLocations(DCL_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = BIL_VAULT_PROXY.toLowerCase();
    if (currentKey === expectedKey) {
      console.log(`BIL (${DCL_ASSET_ID}) already at vault proxy — skipping`);
    } else {
      console.log(`BIL (${DCL_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`);
      txs.push(
        hydrationTx.assetRegistry.update(
          DCL_ASSET_ID,
          null, null, null, null, null, null, null,
          location(BIL_VAULT_PROXY)
        )
      );
    }
  }

  // ---- BIL (asset 55): aToken receipt → register or update location ----
  if (!bilATokenInfo.isSome) {
    txs.push(
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: BIL_ATOKEN_ASSET_ID,
          name: "BIL",
          assetType: "Erc20",
          existentialDeposit: "20000000000000000",
          symbol: "BIL",
          decimals: 18,
          location: location(bilATokenAddress),
          xcmRateLimit: null,
          isSufficient: true,
        })
      )
    );
  } else {
    const locOnChain: any = await apiInst.query.assetRegistry.assetLocations(BIL_ATOKEN_ASSET_ID);
    let currentKey: string | null = null;
    if (locOnChain.isSome) {
      const human: any = locOnChain.toHuman();
      currentKey = human?.interior?.X1?.[0]?.AccountKey20?.key?.toLowerCase?.() ?? null;
    }
    const expectedKey = bilATokenAddress.toLowerCase();
    if (currentKey !== expectedKey) {
      console.log(`BIL (${BIL_ATOKEN_ASSET_ID}) location ${currentKey} != ${expectedKey} — adding assetRegistry.update`);
      txs.push(
        hydrationTx.assetRegistry.update(
          BIL_ATOKEN_ASSET_ID,
          null, null, null, null, null, null, null,
          location(bilATokenAddress)
        )
      );
    } else {
      console.log(`BIL (${BIL_ATOKEN_ASSET_ID}) already at correct location — skipping`);
    }
  }

  // Phase E — fee-payment currencies (HOLLAR price, 1 BIL = 1 HOLLAR at launch).
  // Skip already-accepted to avoid reverting whole batchAll on re-submit.
  const HOLLAR_FEE_PRICE = "10960000000000000000000";
  const dclFee: any = await apiInst.query.multiTransactionPayment.acceptedCurrencies(DCL_ASSET_ID);
  const bilFee: any = await apiInst.query.multiTransactionPayment.acceptedCurrencies(BIL_ATOKEN_ASSET_ID);
  if (!dclFee.isSome) {
    txs.push(hydrationTx.multiTransactionPayment.addCurrency(...Object.values({ asset: DCL_ASSET_ID, price: HOLLAR_FEE_PRICE })));
  } else {
    console.log(`BIL fee currency already accepted — skipping`);
  }
  if (!bilFee.isSome) {
    txs.push(hydrationTx.multiTransactionPayment.addCurrency(...Object.values({ asset: BIL_ATOKEN_ASSET_ID, price: HOLLAR_FEE_PRICE })));
  } else {
    console.log(`BIL fee currency already accepted — skipping`);
  }

  // Approve Pool-Proxy-BIL as managed-balance contract — saves users from
  // running ERC-20 approve() before pool.supply / repay. Idempotent.
  const poolProxyAddress = (await hhre.deployments.get("Pool-Proxy-BIL")).address;
  const evmAccountsQ: any = (apiInst.query as any).evmAccounts ?? (apiInst.query as any).eVMAccounts;
  const evmAccountsTx: any = (hydrationTx as any).evmAccounts ?? (hydrationTx as any).eVMAccounts;
  const approvedEntry: any = await evmAccountsQ.approvedContract(poolProxyAddress);
  if (!approvedEntry.isSome) {
    console.log(`approve Pool-Proxy-BIL (${poolProxyAddress}) for managed-balance access`);
    txs.push(evmAccountsTx.approveContract(poolProxyAddress));
  } else {
    console.log(`Pool-Proxy-BIL already approved — skipping`);
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

  await setInstantBlockModeOnChopsticks(api);
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
