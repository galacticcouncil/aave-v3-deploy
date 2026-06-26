// Propeller fork deploy (chopsticks lark2). EVM ops go via substrate extrinsics
// (no eth RPC on chopsticks). Run while a chopsticks fork listens on ws://localhost:8011.
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { ethers } from "ethers";
import fs from "fs";

const WS = process.env.FORK_WS || "ws://127.0.0.1:8011";
const OUT = "/home/mrq/git/aave-v3-deploy/propeller-vault/out";
const abi = new ethers.utils.AbiCoder();

function creation(name) {
  const j = JSON.parse(fs.readFileSync(`${OUT}/${name}.sol/${name}.json`));
  return j.bytecode.object.startsWith("0x") ? j.bytecode.object : "0x" + j.bytecode.object;
}

async function main() {
  const provider = new WsProvider(WS);
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const send = (m, p) => provider.send(m, p);
  const newBlock = () => send("dev_newBlock", [{ count: 1 }]);

  const keyring = new Keyring({ type: "sr25519" });
  const alice = keyring.addFromUri("//Alice");
  const aliceEvm = ethers.utils.hexlify(api.createType("AccountId", alice.address).toU8a().slice(0, 20));
  console.log("alice substrate:", alice.address);
  console.log("alice evm:", aliceEvm);

  // 1. Whitelist Alice's EVM address as a contract deployer (dev_setStorage).
  const key = api.query.evmAccounts.contractDeployer.key(aliceEvm);
  await send("dev_setStorage", [[[key, "0x"]]]);
  console.log("whitelisted deployer; key", key);
  const isDeployer = await api.query.evmAccounts.contractDeployer(aliceEvm);
  console.log("contractDeployer(alice) present:", !isDeployer.isEmpty || isDeployer.isSome === undefined);

  // 2. Deploy SyntheticToken via evm.create, signed by Alice.
  const ctor = abi.encode(["string", "string", "address"], ["Propeller Synthetic HOLLAR", "psHOLLAR", aliceEvm]);
  const initCode = creation("SyntheticToken") + ctor.slice(2);

  const nonce = (await api.query.evm.accountCodesMetadata) ? 0 : 0; // evm nonce read below
  const tx = api.tx.evm.create(
    aliceEvm,
    initCode,
    "0", // value
    "3000000", // gas limit
    "2000000000000", // max fee per gas
    null, // max priority
    null, // nonce
    [], // access list
    [] // authorization list (EIP-7702)
  );
  const created = await signSendCollect(api, tx, alice, newBlock);
  console.log("evm.create events:", created.map((e) => `${e.section}.${e.method}`).join(", "));
  const createdEvt = created.find((e) => e.section === "evm" && (e.method === "Created" || e.method === "CreatedFailed"));
  console.log("create result:", createdEvt ? `${createdEvt.method} ${JSON.stringify(createdEvt.data.toJSON())}` : "NONE");

  let synthAddr = null;
  if (createdEvt && createdEvt.method === "Created") {
    synthAddr = createdEvt.data.toJSON()[0] || createdEvt.data.toJSON().address;
  }
  console.log("SYNTH:", synthAddr);
  if (synthAddr) {
    const code = await api.query.evm.accountCodes(synthAddr);
    console.log("synth code len:", (code.toU8a().length));
  }
  await api.disconnect();
}

async function signSendCollect(api, tx, signer, newBlock) {
  return new Promise(async (resolve, reject) => {
    let unsub;
    try {
      unsub = await tx.signAndSend(signer, ({ status, events, dispatchError }) => {
        if (status.isReady || status.isBroadcast) newBlock().catch(() => {});
        if (status.isInBlock || status.isFinalized) {
          if (dispatchError) {
            if (dispatchError.isModule) {
              const d = api.registry.findMetaError(dispatchError.asModule);
              console.log("DISPATCH ERROR:", d.section + "." + d.name, d.docs.join(" "));
            } else {
              console.log("DISPATCH ERROR:", dispatchError.toString());
            }
          }
          if (unsub) unsub();
          resolve(events.map((r) => r.event));
        }
      });
      // nudge block production
      setTimeout(() => newBlock().catch(() => {}), 500);
      setTimeout(() => newBlock().catch(() => {}), 2000);
    } catch (e) {
      reject(e);
    }
  });
}

main().catch((e) => {
  console.error("FATAL", e);
  process.exit(1);
});
