// @ts-nocheck
import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { blake2AsHex } from "@polkadot/util-crypto";
import { task } from "hardhat/config";
import ProposalDecoder from "../../helpers/proposal-decoder";

task(
  `enact-on-chopsticks`,
  `Force-execute a hex-encoded call as Root on a chopsticks fork via Scheduler injection`
)
  .addParam("hex", "Hex-encoded call to execute as Root")
  .addOptionalParam("url", "Chopsticks WS URL", "ws://localhost:8011")
  .setAction(async function ({ hex, url }, hre) {
    const api = await ApiPromise.create({
      provider: new WsProvider(url),
      noInitWarn: true,
    });

    const chain = (await api.rpc.system.chain()).toString();
    const head = (await api.rpc.chain.getHeader()).number.toNumber();
    console.log(`Connected to ${chain} @ #${head}`);

    const callHex = hex.startsWith("0x") ? hex : "0x" + hex;
    const callBytes = api.createType("Bytes", callHex);
    const callHash = blake2AsHex(callHex);
    const callLen = (callHex.length - 2) / 2;
    console.log(`Inner call: ${callLen} bytes, hash ${callHash}`);

    // Step 1: ensure preimage is on-chain. If already noted (real mainnet may
    // already have it), skip; else, note it from Alice.
    const existing = await api.query.preimage.preimageFor([callHash, callLen]);
    if (!(existing as any).isNone) {
      console.log(`Preimage already on-chain — skipping notePreimage.`);
    } else {
      const keyring = new Keyring({ type: "sr25519" });
      const alice = keyring.addFromUri("//Alice");
      console.log(`Noting preimage as ${alice.address}…`);
      const noteHash = await new Promise<string>((resolve, reject) => {
        api.tx.preimage
          .notePreimage(callBytes)
          .signAndSend(alice, ({ status, dispatchError }) => {
            if (dispatchError) {
              const msg = dispatchError.toString();
              if (msg.includes("AlreadyNoted") || msg.includes('"index":15')) {
                console.log(`AlreadyNoted — preimage exists, proceeding.`);
                resolve("(already noted)");
              } else {
                reject(new Error(msg));
              }
            }
            if (status.isInBlock) resolve(status.asInBlock.toHex());
          })
          .catch(reject);
      });
      console.log(`Preimage noted in block ${noteHash}`);
    }

    // Step 2: inject Scheduler::Agenda entry at head+2 with origin=Root and
    // call=Lookup{hash, len}. We use head+2 because head+1 will be produced
    // immediately by dev_newBlock and we want the agenda set BEFORE that block.
    const newHead = (await api.rpc.chain.getHeader()).number.toNumber();
    const targetBlock = newHead + 1;
    console.log(`Scheduling Root dispatch at #${targetBlock}…`);

    const scheduled = {
      maybeId: null,
      priority: 0,
      call: { Lookup: { hash_: callHash, len: callLen } },
      maybePeriodic: null,
      origin: { system: "Root" },
    };

    await (api.rpc as any)("dev_setStorage", {
      Scheduler: {
        Agenda: [[[targetBlock], [scheduled]]],
      },
    });

    // Step 3: produce a block (the one that runs the agenda).
    console.log("Producing block…");
    await (api.rpc as any)("dev_newBlock", { count: 1 });

    // Step 4: read events and decode.
    const dispatchBlockHash = (await api.rpc.chain.getBlockHash(targetBlock)).toHex();
    const apiAt = await api.at(dispatchBlockHash);
    const events = (await apiAt.query.system.events()) as any;

    console.log(`\n=== events in #${targetBlock} (${dispatchBlockHash}) ===`);
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    let dispatchOk = true;
    let sawScheduled = false;
    for (const { event, phase } of events) {
      const sec = event.section;
      const meth = event.method;
      if (sec === "system" && meth === "ExtrinsicSuccess") continue;
      if (sec === "system" && meth === "ExtrinsicFailed") continue;
      if (sec === "scheduler" && meth === "Dispatched") sawScheduled = true;
      if (sec === "scheduler" && (meth === "CallUnavailable" || meth === "PeriodicFailed" || meth === "PermanentlyOverweight"))
        dispatchOk = false;
      let detail = event.data.toHuman();
      if (sec === "system" && meth === "ExtrinsicFailed") dispatchOk = false;
      console.log(`  ${sec}.${meth} ${JSON.stringify(detail)}`);
    }

    console.log("");
    console.log(`scheduler.Dispatched seen : ${sawScheduled}`);
    console.log(`overall dispatch ok       : ${dispatchOk}`);

    await api.disconnect();
  });
