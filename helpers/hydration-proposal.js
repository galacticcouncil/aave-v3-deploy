const { ApiPromise, WsProvider } = require("@polkadot/api");
const ethers = require("ethers");

function account(address) {
  const prefix = Buffer.from("ETH\0");
  const addressBuffer = Buffer.from(address.replace("0x", ""), "hex");
  const remainingBytes = 32 - prefix.length - addressBuffer.length;
  const padding = Buffer.alloc(remainingBytes);
  return "0x" + Buffer.concat([prefix, addressBuffer, padding]).toString("hex");
}

function padAddress(address) {
  const stripped = address.replace("0x", "");
  const padded = stripped.padEnd(64, "0");
  return "0x" + padded;
}

const location = (contract) => ({
  parents: "0",
  interior: {
    X1: {
      AccountKey20: {
        network: null,
        key: contract,
      },
    },
  },
});

async function generateProposal(transactions, from, registerAssets = []) {
  const provider = new WsProvider(process.env.RPC || "wss://rpc.hydradx.cloud");
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const { utility, evm, assetRegistry } = api.tx;

  const evmAddress = (account) =>
    ethers.utils.hexlify(
      api.createType("AccountId", account).toU8a().slice(0, 20)
    );

  const evmCall = ({
    from,
    to,
    data,
    gas = "1000000",
    gasPrice = "600000000",
  }) =>
    evm.call(
      evmAddress(from),
      to,
      data,
      "0",
      gas,
      gasPrice,
      undefined,
      undefined,
      []
    );
  const rootEvmCall = ({
    from,
    to,
    data,
    gas = "1000000",
    gasPrice = "600000000",
  }) =>
    utility.dispatchAs(
      { system: { signed: from } },
      evmCall({ from, to, data, gas, gasPrice })
    );

  const registerAsset = ({ asset, address, symbol }) =>
    assetRegistry.register(
      asset,
      symbol,
      "Erc20",
      0,
      symbol,
      10,
      location(address),
      null,
      true
    );

  const batch = [
    ...transactions.map((tx) =>
      rootEvmCall({
        ...tx,
        from: from ? padAddress(from) : padAddress(tx.from),
      })
    ),
    ...registerAssets.map(registerAsset),
  ];

  const extrinsic = utility.batchAll(batch);
  const batchCallData = extrinsic.method.toHex();

  await api.disconnect();
  return batchCallData;
}

module.exports = {
  generateProposal,
};
