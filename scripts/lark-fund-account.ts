// Fund a substrate (or EVM-truncated) account on a lark testnet, atomically.
// Replaces the previous fund-deployer-lark2 / fund-deployer-weth / fund-bob-lark2
// one-off scripts with a single parameterised CLI.
//
// Usage:
//   WS_URL=wss://2.lark.hydration.cloud \
//   TARGET=//Bob HDX=1000 WETH=0.1 \
//     npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
//     scripts/lark-fund-account.ts
//
// TARGET formats:
//   - "//Alice", "//Bob", ... — derived sr25519 dev account
//   - "0x222222...9531"        — EVM address (transferred to its truncated
//                                substrate account = ETH\0 + addr + zeros)
//   - "7KAT...Kri5"            — substrate SS58 address
//
// HDX  — amount in whole units (12 decimals), e.g. "1000"
// WETH — amount in whole units (18 decimals), e.g. "0.1"
//
// Funder defaults to //Alice (the only pre-funded testnet account).

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { hexToU8a, u8aToHex } from "@polkadot/util";
import { encodeAddress, decodeAddress } from "@polkadot/util-crypto";

const WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const TARGET = process.env.TARGET;
const HDX = process.env.HDX || "0";
const WETH = process.env.WETH || "0";
const FUNDER_URI = process.env.FUNDER_URI || "//Alice";
const HYDRATION_PREFIX = 63;
const WETH_ASSET_ID = 20;

if (!TARGET) {
  console.error("TARGET env var required (//Bob or 0x... or SS58)");
  process.exit(1);
}

function toBaseUnits(human: string, decimals: number): bigint {
  if (!human || human === "0") return 0n;
  const [whole, frac = ""] = human.split(".");
  const padded = (frac + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

function resolveTarget(target: string): string {
  // Dev URI
  if (target.startsWith("//")) {
    return new Keyring({ type: "sr25519" }).addFromUri(target).address;
  }
  // EVM address → truncated substrate account (ETH\0 + 20-byte EVM + 8 zero bytes)
  if (target.startsWith("0x") && target.length === 42) {
    const buf = new Uint8Array(32);
    buf[0] = 0x45; buf[1] = 0x54; buf[2] = 0x48; buf[3] = 0x00;
    buf.set(hexToU8a(target), 4);
    return encodeAddress(buf, HYDRATION_PREFIX);
  }
  // Already a substrate address — verify it parses
  decodeAddress(target);
  return target;
}

async function main() {
  const api = await ApiPromise.create({ provider: new WsProvider(WS) });
  const funder = new Keyring({ type: "sr25519" }).addFromUri(FUNDER_URI);
  const recipient = resolveTarget(TARGET!);
  const hdxAmount = toBaseUnits(HDX, 12);
  const wethAmount = toBaseUnits(WETH, 18);

  console.log(`Funder:    ${FUNDER_URI} (${funder.address})`);
  console.log(`Recipient: ${TARGET} → ${recipient}`);
  console.log(`HDX:       ${HDX} (${hdxAmount} base)`);
  console.log(`WETH:      ${WETH} (${wethAmount} base)`);

  const txs: any[] = [];
  if (hdxAmount > 0n) txs.push(api.tx.balances.transferKeepAlive(recipient, hdxAmount.toString()));
  if (wethAmount > 0n) txs.push(api.tx.tokens.transfer(recipient, WETH_ASSET_ID, wethAmount.toString()));
  if (txs.length === 0) {
    console.error("nothing to transfer (set HDX and/or WETH)");
    process.exit(1);
  }
  const tx = txs.length === 1 ? txs[0] : api.tx.utility.batchAll(txs);

  await new Promise<void>((resolve, reject) => {
    tx.signAndSend(funder, ({ status, dispatchError, events }: any) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return reject(new Error(`${d.section}.${d.name}`));
          }
          return reject(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") {
            return reject(new Error("ExtrinsicFailed"));
          }
        }
        console.log("  OK");
        resolve();
      }
    }).catch(reject);
  });

  // Verify
  const post: any = await api.query.system.account(recipient);
  const postWeth: any = await api.query.tokens.accounts(recipient, WETH_ASSET_ID);
  console.log(`\nrecipient balance now:`);
  console.log(`  HDX free:  ${Number(post.data.free.toBigInt() / 10n ** 12n).toLocaleString()}`);
  console.log(`  WETH free: ${postWeth.free.toString()} (${Number(postWeth.free.toBigInt()) / 1e18} WETH)`);

  await api.disconnect();
}
main().catch((e) => { console.error(`FAILED: ${e.message}`); process.exit(1); });
