#!/usr/bin/env node
/**
 * Funds an EVM address on Hydration testnet (lark) with WETH for gas and HDX.
 *
 * Since there's no sudo on lark, this uses fast governance (1-block periods on testnet)
 * to execute `currencies.updateBalance` as root via a GeneralAdmin referendum.
 *
 * Truncated Substrate AccountId for an unbound EVM address:
 *   "ETH\0" (4 bytes) + evm_address (20 bytes) + 0x00 (8 bytes) = 32 bytes
 *
 * Usage:
 *   node fund-evm.mjs [--rpc wss://2.lark.hydration.cloud] [--evm-address 0x...] [--weth 1] [--hdx 100]
 */

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aConcat, hexToU8a } from "@polkadot/util";
import { blake2AsHex, encodeAddress } from "@polkadot/util-crypto";

const args = process.argv.slice(2);
function getArg(flag, fallback) {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : fallback;
}

const RPC = getArg("--rpc", "wss://2.lark.hydration.cloud");
const EVM_ADDRESS = getArg("--evm-address", "0x222222B60cA97a4998B7D07b99034Fa4d9339531");
const WETH_ASSET_ID = 20;
const HDX_ASSET_ID = 0;
const WETH_AMOUNT = BigInt(getArg("--weth", "1")) * 10n ** 18n;
const HDX_AMOUNT = BigInt(getArg("--hdx", "100")) * 10n ** 12n;

// "ETH\0" + H160 + 8 zero bytes
function evmToSubstrateAccount(evmAddress) {
  const prefix = new Uint8Array([0x45, 0x54, 0x48, 0x00]);
  const addr = hexToU8a(evmAddress);
  const padding = new Uint8Array(8);
  return u8aConcat(prefix, addr, padding);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function sendAndWait(tx, signer, api) {
  return new Promise((resolve, reject) => {
    tx.signAndSend(signer, ({ status, events, dispatchError }) => {
      if (dispatchError) {
        if (dispatchError.isModule) {
          const decoded = api.registry.findMetaError(dispatchError.asModule);
          reject(new Error(`${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`));
        } else {
          reject(new Error(dispatchError.toString()));
        }
        return;
      }
      if (status.isInBlock) {
        resolve({ blockHash: status.asInBlock, events });
      }
    });
  });
}

async function executeViaGovernance(api, alice, call, label) {
  const encodedCall = call.method.toHex();
  const encodedHash = blake2AsHex(encodedCall);

  // 1. Note preimage
  console.log(`  [1/4] Noting preimage for: ${label}`);
  try {
    await sendAndWait(api.tx.preimage.notePreimage(encodedCall), alice, api);
  } catch (err) {
    if (!err.message.includes("AlreadyNoted")) throw err;
    console.log("    Already noted, skipping.");
  }

  // 2. Submit referendum
  console.log("  [2/4] Submitting referendum (Root track)...");
  const proposal = { Lookup: { hash: encodedHash, len: encodedCall.length / 2 - 1 } };
  const { events: submitEvents } = await sendAndWait(
    api.tx.referenda.submit({ system: "Root" }, proposal, { After: 1 }),
    alice,
    api
  );
  const submittedEvent = submitEvents.find(
    ({ event }) => event.section === "referenda" && event.method === "Submitted"
  );
  if (!submittedEvent) throw new Error("No Submitted event found");
  const refIndex = submittedEvent.event.data[0].toNumber();
  console.log(`    Referendum #${refIndex} submitted.`);

  // 3. Place deposit + vote
  console.log("  [3/4] Placing deposit + voting AYE...");
  await sendAndWait(api.tx.referenda.placeDecisionDeposit(refIndex), alice, api);
  const { data: aliceData } = await api.query.system.account(alice.address);
  const voteAmount = aliceData.free.toBigInt() * 9n / 10n;
  await sendAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { balance: voteAmount, vote: { aye: true, conviction: "None" } },
    }),
    alice,
    api
  );

  // 4. Wait for approval
  console.log("  [4/4] Waiting for referendum to pass...");
  for (let i = 0; i < 60; i++) {
    await sleep(6000);
    const info = await api.query.referenda.referendumInfoFor(refIndex);
    const infoJson = info.toJSON();
    if (infoJson.approved) {
      console.log(`    Referendum #${refIndex} approved!`);
      return;
    }
    if (infoJson.rejected) throw new Error(`Referendum #${refIndex} rejected`);
    if (infoJson.timedOut) throw new Error(`Referendum #${refIndex} timed out`);
    const ongoing = infoJson.ongoing;
    if (ongoing?.deciding) {
      console.log(`    Waiting... (confirming=${!!ongoing.deciding.confirming})`);
    }
  }
  throw new Error("Referendum did not pass in time");
}

async function main() {
  console.log(`Connecting to ${RPC}...`);
  const provider = new WsProvider(RPC);
  const api = await ApiPromise.create({ provider });

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");

  const substrateAccount = evmToSubstrateAccount(EVM_ADDRESS);
  const ss58Address = encodeAddress(substrateAccount, api.registry.chainSS58);

  console.log(`Alice Substrate:  ${alice.address}`);
  console.log(`EVM address:      ${EVM_ADDRESS}`);
  console.log(`Mapped Substrate: ${ss58Address}`);

  // Batch: mint WETH + HDX to the truncated EVM account
  const batchCall = api.tx.utility.batchAll([
    api.tx.currencies.updateBalance(ss58Address, WETH_ASSET_ID, WETH_AMOUNT.toString()),
    api.tx.currencies.updateBalance(ss58Address, HDX_ASSET_ID, HDX_AMOUNT.toString()),
  ]);

  console.log(`\nMinting ${WETH_AMOUNT / 10n ** 18n} WETH + ${HDX_AMOUNT / 10n ** 12n} HDX via governance...`);
  await executeViaGovernance(api, alice, batchCall, "Fund EVM (WETH + HDX)");

  // Verify
  await sleep(6000);
  const wethBal = await api.query.tokens.accounts(ss58Address, WETH_ASSET_ID);
  const { data: hdxBal } = await api.query.system.account(ss58Address);
  console.log(`\nWETH balance: ${wethBal.free.toString()} (${BigInt(wethBal.free.toString()) / 10n ** 18n} WETH)`);
  console.log(`HDX balance:  ${hdxBal.free.toString()} (${BigInt(hdxBal.free.toString()) / 10n ** 12n} HDX)`);
  console.log("Done!");

  await api.disconnect();
}

main().catch((err) => {
  console.error("FAILED:", err.message);
  process.exit(1);
});
