// Enact the GIGAHDX launch batchAll as Root on the chopsticks fork (NOT mainnet).
// Reads the preimage hex printed by phase 6, notes it as a preimage, then injects
// a Root-origin Scheduler entry and builds the block so the scheduler dispatches it.
const { ApiPromise, WsProvider, Keyring } = require("@polkadot/api");
const fs = require("fs");

(async () => {
  const api = await ApiPromise.create({ provider: new WsProvider("ws://localhost:8011"), noInitWarn: true });

  // 1. extract the batchAll extrinsic hex printed after "submit preimages:"
  const lines = fs.readFileSync(process.env.LAUNCH_LOG || "/tmp/deploy-pathA.log", "utf8").split("\n");
  const idx = lines.findIndex((l) => l.includes("submit preimages:"));
  const hex = lines.slice(idx + 1).map((l) => l.trim()).find((l) => /^0x[0-9a-fA-F]{200,}$/.test(l));
  if (!hex) throw new Error("preimage hex not found in log");
  const call = api.createType("Call", hex);
  const callHex = call.toHex();
  const callHash = call.hash.toHex();
  const len = (callHex.length - 2) / 2;
  console.log(`batchAll: ${call.section}.${call.method}, ${len} bytes, hash ${callHash}`);

  // 2. fund Alice (sr25519 dev key) so she can sign notePreimage
  const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
  await api.rpc("dev_setStorage", {
    System: { Account: [[[alice.address], { providers: 1, sufficients: 1, data: { free: "1000000000000000000000000", reserved: "0", frozen: "0", flags: "0" } }]] },
  });
  console.log("funded Alice", alice.address);

  // 3. note the preimage (Instant mode seals the tx into a block)
  const already = await api.query.preimage.statusFor(callHash);
  if (already.isSome) {
    console.log("preimage already noted");
  } else {
    await new Promise((res, rej) => {
      api.tx.preimage.notePreimage(callHex).signAndSend(alice, ({ status, dispatchError }) => {
        if (dispatchError) return rej(new Error(dispatchError.toString()));
        if (status.isInBlock || status.isFinalized) res();
      }).catch(rej);
    });
    console.log("preimage noted");
  }

  // 4. inject a Root-origin scheduler entry at the next block (Lookup -> preimage)
  const when = (await api.rpc.chain.getHeader()).number.toNumber() + 1;
  await api.rpc("dev_setStorage", {
    Scheduler: {
      Agenda: [[[when], [{
        maybeId: null,
        priority: 0,
        call: { Lookup: { hash: callHash, len } },
        maybePeriodic: null,
        origin: { system: "Root" },
      }]]],
    },
  });
  console.log(`scheduled batchAll as Root at block ${when}`);

  // 5. build the block so the scheduler dispatches it
  await api.rpc("dev_newBlock", {});

  // 6. inspect events
  const events = await api.query.system.events();
  let dispatched = null, batchOk = null, failures = [];
  for (const { event } of events) {
    const k = `${event.section}.${event.method}`;
    if (k === "scheduler.Dispatched") dispatched = event.data.toHuman();
    if (k === "utility.BatchCompleted") batchOk = true;
    if (k === "utility.BatchInterrupted") failures.push(event.data.toHuman());
    if (k === "system.ExtrinsicFailed") failures.push(event.data.toHuman());
  }
  console.log("scheduler.Dispatched:", JSON.stringify(dispatched));
  console.log("utility.BatchCompleted:", batchOk);
  if (failures.length) console.log("FAILURES:", JSON.stringify(failures, null, 2));
  await api.disconnect();
})().catch((e) => { console.error("ENACT ERROR:", e.stack || e.message); process.exit(1); });
