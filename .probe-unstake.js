const { ApiPromise, WsProvider, Keyring } = require("@polkadot/api");
const { cryptoWaitReady } = require("@polkadot/util-crypto");
const { ethers } = require("ethers");
(async () => {
  await cryptoWaitReady();
  const api = await ApiPromise.create({ provider: new WsProvider("wss://2.lark.hydration.cloud") });
  const bob = new Keyring({ type: "sr25519" }).addFromUri("//Bob");
  const ATOKEN = "0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661";
  const bobEvm = "0x8eaf04151687736326c9fea17e25fc5287613693";
  const p = new ethers.providers.JsonRpcProvider("https://2.lark.hydration.cloud");

  const erc20 = new ethers.utils.Interface(["function balanceOf(address) view returns (uint256)"]);
  const balBefore = ethers.BigNumber.from(await p.call({ to: ATOKEN, data: erc20.encodeFunctionData("balanceOf", [bobEvm]) }));
  console.log("Bob aToken balance before:", balBefore.toString());

  // Probe pendingUnstakes BEFORE
  const pre = await api.query.gigaHdx.pendingUnstakes(bob.address);
  console.log("Bob pendingUnstakes before:", pre.toJSON());

  // Try gigaUnstake(10 stHDX = 10 * 10^12)
  const amt = "10000000000000";
  const tx = api.tx.gigaHdx.gigaUnstake(amt);
  console.log(`\nSubmitting gigaHdx.gigaUnstake(${amt})...`);
  await new Promise((res, rej) => {
    tx.signAndSend(bob, ({ status, dispatchError, events }) => {
      if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
      if (status.isFinalized) {
        if (dispatchError) {
          if (dispatchError.isModule) {
            const d = api.registry.findMetaError(dispatchError.asModule);
            return rej(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
          }
          return rej(new Error(dispatchError.toString()));
        }
        for (const { event } of events) {
          if (event.section === "system" && event.method === "ExtrinsicFailed") return rej(new Error(`failed: ${event.data}`));
          if (event.section === "gigaHdx") console.log(`  event: gigaHdx.${event.method} = ${event.data.toString().slice(0, 200)}`);
        }
        console.log("  OK");
        res(events);
      }
    }).catch(rej);
  });

  const balAfter = ethers.BigNumber.from(await p.call({ to: ATOKEN, data: erc20.encodeFunctionData("balanceOf", [bobEvm]) }));
  console.log("\nBob aToken balance after:", balAfter.toString());
  const post = await api.query.gigaHdx.pendingUnstakes(bob.address);
  console.log("Bob pendingUnstakes after:", post.toJSON());

  await api.disconnect();
})().catch(e => { console.error("FAILED:", e.message); process.exit(1); });
