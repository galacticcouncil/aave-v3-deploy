const { ApiPromise, WsProvider } = require("@polkadot/api");
const { stringToU8a } = require("@polkadot/util");
const { encodeAddress } = require("@polkadot/util-crypto");

(async () => {
  const api = await ApiPromise.create({ provider: new WsProvider("ws://localhost:8011"), noInitWarn: true });
  const evm = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";
  const acc = new Uint8Array(32);
  acc.set(stringToU8a("ETH\0"), 0);
  acc.set(Buffer.from(evm.slice(2), "hex"), 4);
  const ss58 = encodeAddress(acc, api.registry.chainSS58);

  const valTypeId = api.query.evmAccounts.contractDeployer.creator.meta.type.asMap.value.toNumber();
  const valName = api.registry.createLookupType(valTypeId);
  console.log("ContractDeployer value type:", valTypeId, valName);
  const cdKey = api.query.evmAccounts.contractDeployer.key(evm);
  let cdVal = "0x";
  try { cdVal = api.createType(valName, valName === "bool" ? true : undefined).toHex(); } catch (e) {}
  if (cdVal === "0x00") cdVal = "0x01";
  console.log("cd key:", cdKey, "val:", cdVal);

  const HDX = (10000n * 10n ** 12n).toString();
  const WETH = (100n * 10n ** 18n).toString();

  const set1 = await api.rpc("dev_setStorage", {
    System: { Account: [[[ss58], { providers: 1, sufficients: 1, data: { free: HDX, reserved: "0", frozen: "0", flags: "0" } }]] },
    Tokens: { Accounts: [[[ss58, 20], { free: WETH, reserved: "0", frozen: "0" }]] },
  });
  console.log("set1(System,Tokens):", set1.toString());
  const set2 = await api.rpc("dev_setStorage", [[cdKey, cdVal]]);
  console.log("set2(ContractDeployer):", set2.toString());

  console.log("--- after ---");
  console.log("ss58:", ss58);
  console.log("sys HDX free:", (await api.query.system.account(ss58)).data.free.toString());
  console.log("WETH(20) free:", (await api.query.tokens.accounts(ss58, 20)).free.toString());
  console.log("contractDeployer(evm):", (await api.query.evmAccounts.contractDeployer(evm)).toHuman());
  await api.disconnect();
})().catch((e) => { console.error("ERR", e.stack || e.message); process.exit(1); });
