// @ts-nocheck
import { task } from "hardhat/config";
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { cryptoWaitReady, blake2AsHex } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const LARK_WS = "wss://node.lark.hydration.cloud";
const LARK_HTTP = "https://node.lark.hydration.cloud";
const AAVE_MANAGER = "0xAa7e0000000000000000000000000000000Aa7e0";
const AAVE_ORACLE = "0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760";
const PRIME_TOKEN = "0x000000000000000000000000000000010000002b";
const NEW_SOURCE = "0x166f286745171D58B6b16E6020f7e48246c816E3";
const OLD_SOURCE = "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307";

function sendAndWait(tx: any, signer: any, api: ApiPromise): Promise<any> {
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, events, dispatchError }: any) => {
      if (dispatchError) {
        if (dispatchError.isModule) {
          const decoded = api.registry.findMetaError(dispatchError.asModule);
          reject(
            new Error(
              `${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`
            )
          );
        } else {
          reject(new Error(dispatchError.toString()));
        }
        return;
      }
      if (status.isInBlock) resolve({ blockHash: status.asInBlock, events });
    }).catch(reject);
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function executeViaGovernance(
  api: ApiPromise,
  alice: any,
  call: any,
  label: string
) {
  const encodedCall = call.method.toHex();
  const encodedHash = blake2AsHex(encodedCall);

  console.log(`  Gov: noting preimage for ${label}...`);
  try {
    await sendAndWait(api.tx.preimage.notePreimage(encodedCall), alice, api);
  } catch (err: any) {
    if (!err.message.includes("AlreadyNoted")) throw err;
    console.log("  Gov: preimage already noted");
  }

  console.log(`  Gov: submitting referendum (Root track)...`);
  const proposal = {
    Lookup: { hash: encodedHash, len: encodedCall.length / 2 - 1 },
  };
  const { events: submitEvents } = await sendAndWait(
    api.tx.referenda.submit({ system: "Root" }, proposal, { After: 1 }),
    alice,
    api
  );
  const submittedEvent = submitEvents.find(
    ({ event }: any) =>
      event.section === "referenda" && event.method === "Submitted"
  );
  if (!submittedEvent) throw new Error("No Submitted event found");
  const refIndex = submittedEvent.event.data[0].toNumber();
  console.log(`  Gov: referendum #${refIndex} submitted`);

  await sendAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex),
    alice,
    api
  );
  console.log(`  Gov: decision deposit placed`);

  const { data: aliceData } = await api.query.system.account(alice.address);
  const voteAmount = ((aliceData as any).free.toBigInt() * 9n) / 10n;
  await sendAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: {
        balance: voteAmount,
        vote: { aye: true, conviction: "None" },
      },
    }),
    alice,
    api
  );
  console.log(`  Gov: voted aye with ${voteAmount.toString()}`);

  console.log(`  Gov: waiting for referendum #${refIndex}...`);
  for (let i = 0; i < 120; i++) {
    await sleep(6000);
    const info = await api.query.referenda.referendumInfoFor(refIndex);
    const infoJson = (info as any).toJSON();
    if (infoJson.approved) {
      console.log(`  Gov: referendum #${refIndex} approved`);
      return refIndex;
    }
    if (infoJson.rejected)
      throw new Error(`Referendum #${refIndex} rejected`);
    if (infoJson.timedOut)
      throw new Error(`Referendum #${refIndex} timed out`);
  }
  throw new Error("Referendum did not pass in time (12 minute budget)");
}

task(
  "enact-prime-oracle-lark",
  "Submit + execute the PRIME -> ClampedOracle swap on node.lark via OpenGov Root track, signed by //Alice"
).setAction(async function () {
  await cryptoWaitReady();

  const provider = new WsProvider(LARK_WS);
  const api = await ApiPromise.create({ provider, noInitWarn: true });

  // Pre-flight check.
  const httpProvider = new ethers.providers.JsonRpcProvider(LARK_HTTP);
  const oracle = new ethers.Contract(
    AAVE_ORACLE,
    [
      "function getSourceOfAsset(address) view returns (address)",
      "function getAssetPrice(address) view returns (uint256)",
    ],
    httpProvider
  );
  const sourceBefore = await oracle.getSourceOfAsset(PRIME_TOKEN);
  const priceBefore = await oracle.getAssetPrice(PRIME_TOKEN);
  console.log(`PRIME source before: ${sourceBefore}`);
  console.log(`PRIME price before:  ${priceBefore.toString()}`);
  if (sourceBefore.toLowerCase() === NEW_SOURCE.toLowerCase()) {
    console.log("already at NEW_SOURCE -- nothing to do");
    await api.disconnect();
    return;
  }
  if (sourceBefore.toLowerCase() !== OLD_SOURCE.toLowerCase()) {
    console.log(
      `warning: source ${sourceBefore} differs from expected ${OLD_SOURCE}`
    );
  }

  // Build the same call the proposal task would: batchAll([dispatchAsAaveManager(evm.call(setAssetSources))]).
  const iface = new ethers.utils.Interface([
    "function setAssetSources(address[],address[])",
  ]);
  const callData = iface.encodeFunctionData("setAssetSources", [
    [PRIME_TOKEN],
    [NEW_SOURCE],
  ]);
  const evmCall = api.tx.evm.call(
    AAVE_MANAGER,
    AAVE_ORACLE,
    callData,
    "0",
    "600000",
    "600000000",
    null,
    null,
    [],
    []
  );
  const dispatched = api.tx.dispatcher.dispatchAsAaveManager(evmCall);
  const batch = api.tx.utility.batchAll([dispatched]);

  console.log(`call hex: ${batch.method.toHex()}`);
  console.log(
    `call hash: ${blake2AsHex(batch.method.toHex())}`
  );

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  console.log(`signing as //Alice (${alice.address})`);

  await executeViaGovernance(api, alice, batch, "swap PRIME oracle source");

  // Post-flight: confirm the swap took effect.
  const sourceAfter = await oracle.getSourceOfAsset(PRIME_TOKEN);
  const priceAfter = await oracle.getAssetPrice(PRIME_TOKEN);
  console.log(`PRIME source after: ${sourceAfter}`);
  console.log(`PRIME price after:  ${priceAfter.toString()}`);

  if (sourceAfter.toLowerCase() === NEW_SOURCE.toLowerCase()) {
    console.log("swap succeeded");
  } else {
    console.error("swap did NOT take effect");
  }

  await api.disconnect();
});
