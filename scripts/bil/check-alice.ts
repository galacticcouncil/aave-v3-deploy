// Check Alice's status on lark 1 and whitelist our EVM deployer via sudo if possible.
// Alice (SR25519) cannot sign EVM transactions directly, but she typically has sudo
// on lark test chains, so she can call sudo.sudo(evmAccounts.addContractDeployer(...))
// to whitelist our ECDSA deployer address.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { u8aToHex } from "@polkadot/util";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const EVM_DEPLOYER = "0x222222B60cA97a4998B7D07b99034Fa4d9339531"; // our hardhat deployer

async function main() {
  const args = process.argv.slice(2);
  const whitelist = args.includes("--whitelist");

  console.log(`Connecting to ${LARK_WS}...`);
  const provider = new WsProvider(LARK_WS);
  const api = await ApiPromise.create({ provider });

  const chain = await api.rpc.system.chain();
  const name = await api.rpc.system.name();
  console.log(`Connected: ${name} / ${chain}`);

  // Alice's keypair from //Alice derivation (standard Substrate dev key)
  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  console.log(`\nAlice substrate address: ${alice.address}`);
  console.log(`Alice substrate pubkey:  ${u8aToHex(alice.publicKey)}`);
  console.log(`Alice default EVM addr:  0x${u8aToHex(alice.publicKey).slice(2, 42)}`);

  // Check Alice's substrate balance
  const accountInfo: any = await api.query.system.account(alice.address);
  const free = accountInfo.data.free.toBigInt();
  console.log(`Alice substrate balance: ${free} (${Number(free) / 1e12} HDX @ 12dec)`);

  // Check if sudo pallet exists
  let sudoAvailable = false;
  let sudoKey: string | null = null;
  try {
    const k: any = await api.query.sudo.key();
    sudoKey = k.isSome ? k.unwrap().toString() : k.toString();
    sudoAvailable = true;
    console.log(`\nSudo key: ${sudoKey}`);
    console.log(`Alice IS sudo: ${sudoKey === alice.address}`);
  } catch (e) {
    console.log(`\nNo sudo pallet / not accessible: ${(e as Error).message}`);
  }

  // Check if our deployer is already whitelisted
  let isWhitelisted = false;
  try {
    const entry: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
    isWhitelisted = entry.isSome;
    console.log(`\n${EVM_DEPLOYER} whitelisted: ${isWhitelisted}`);
  } catch (e) {
    console.log(`\nFailed to query contractDeployer: ${(e as Error).message}`);
  }

  // Also check Alice's EVM-mapped address
  const aliceEvmAddr = "0x" + u8aToHex(alice.publicKey).slice(2, 42);
  try {
    const entry: any = await api.query.evmAccounts.contractDeployer(aliceEvmAddr);
    console.log(`Alice's EVM addr ${aliceEvmAddr} whitelisted: ${entry.isSome}`);
  } catch (e) {}

  if (!whitelist) {
    console.log(`\n[dry-run] Re-run with --whitelist to submit addContractDeployer tx`);
    await api.disconnect();
    return;
  }

  if (isWhitelisted) {
    console.log("Already whitelisted, nothing to do");
    await api.disconnect();
    return;
  }

  if (!sudoAvailable || sudoKey !== alice.address) {
    console.log(`\nCan't whitelist: Alice is not sudo. Sudo key: ${sudoKey}`);
    await api.disconnect();
    process.exit(1);
  }

  // Submit sudo.sudo(evmAccounts.addContractDeployer(EVM_DEPLOYER))
  console.log(`\nSubmitting sudo.sudo(evmAccounts.addContractDeployer(${EVM_DEPLOYER}))...`);
  const inner = api.tx.evmAccounts.addContractDeployer(EVM_DEPLOYER);
  const call = api.tx.sudo.sudo(inner);

  await new Promise<void>((resolve, reject) => {
    call.signAndSend(alice, ({ status, dispatchError, events }) => {
      if (status.isInBlock) {
        console.log(`  in block: ${status.asInBlock.toHex()}`);
      }
      if (status.isFinalized) {
        console.log(`  finalized: ${status.asFinalized.toHex()}`);
        if (dispatchError) {
          if (dispatchError.isModule) {
            const decoded = api.registry.findMetaError(dispatchError.asModule);
            console.error(`  ERROR: ${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`);
            reject(new Error(`${decoded.section}.${decoded.name}`));
          } else {
            console.error(`  ERROR: ${dispatchError.toString()}`);
            reject(new Error(dispatchError.toString()));
          }
        } else {
          // Inspect sudid result
          for (const { event } of events) {
            if (event.section === "sudo" && event.method === "Sudid") {
              const result = event.data[0] as any;
              if (result.isErr) {
                const err = result.asErr;
                if (err.isModule) {
                  const decoded = api.registry.findMetaError(err.asModule);
                  console.error(`  sudo inner ERR: ${decoded.section}.${decoded.name}`);
                  reject(new Error("sudo call failed"));
                  return;
                }
              } else {
                console.log(`  sudo inner OK`);
              }
            }
          }
          resolve();
        }
      }
    }).catch(reject);
  });

  // Verify
  const postCheck: any = await api.query.evmAccounts.contractDeployer(EVM_DEPLOYER);
  console.log(`\n${EVM_DEPLOYER} whitelisted (post): ${postCheck.isSome}`);

  await api.disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
