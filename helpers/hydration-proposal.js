const { ApiPromise, WsProvider } = require("@polkadot/api");
const { map } = require("bluebird");
const ethers = require("ethers");
const { getAddress } = require("ethers/lib/utils");

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

async function generateProposal(
  transactions,
  from,
  registerAssets = [],
  whitelist = false,
  newFeePaymentAssets = [],
  dispatchAsSell = [],
  createPoolsWithPegs = [],
  stableswapAddLiquidityAs = []
) {
  const provider = new WsProvider(
    process.env.RPC
      ? process.env.RPC.replace(/^http:\/\//, "ws://").replace(
          /^https:\/\//,
          "wss://"
        )
      : "wss://rpc.hydradx.cloud"
  );
  const api = await ApiPromise.create({ provider, noInitWarn: true });
  const {
    utility,
    evm,
    assetRegistry,
    multiTransactionPayment,
    tokens,
    router,
    stableswap,
  } = api.tx;

  const evmAddress = (account) =>
    ethers.utils.hexlify(
      api.createType("AccountId", account).toU8a().slice(0, 20)
    );

  const evmCall = ({
    from,
    to,
    data,
    gas = "100000",
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
    gas = "100000",
    gasPrice = "600000000",
  }) =>
    utility.dispatchAs(
      { system: { signed: from } },
      evmCall({ from, to, data, gas, gasPrice })
    );

  const registerAsset = ({
    asset,
    address,
    symbol,
    decimals,
    name,
    assetType,
    existentialDeposit,
  }) =>
    assetRegistry.register(
      asset,
      name ? name : symbol,
      assetType ? assetType : "Erc20",
      existentialDeposit ? existentialDeposit : 0,
      symbol,
      decimals,
      address ? location(address) : null,
      null,
      true
    );

  const addFeePaymentAsset = ({ asset, price }) =>
    multiTransactionPayment.addCurrency(asset, price);

  const forceTransfer = ({ source, dest, id, amount }) =>
    tokens.forceTransfer(source, dest, id, amount);

  const dispatchSell = ({ asOrigin, assetIn, assetOut, amount, route }) =>
    utility.dispatchAs(
      { system: { signed: asOrigin } },
      router.sell(assetIn, assetOut, amount, 0, route)
    );

  const createPoolWithPegs = ({
    shareAsset,
    assets,
    amplification,
    fee,
    pegSource,
    maxPegUpdate,
  }) =>
    stableswap.createPoolWithPegs(
      shareAsset,
      assets,
      amplification,
      fee,
      pegSource,
      maxPegUpdate
    );

  const sswapAddLiquidityAs = ({ origin, poolId, assets }) =>
    utility.dispatchAs(
      { system: { signed: origin } },
      stableswap.addLiquidity(poolId, assets)
    );

  const batch = [
    ...registerAssets.map(registerAsset),
    ...transactions.map((tx) =>
      rootEvmCall({
        ...tx,
        gas: tx.gasLimit?.toString(),
        from: from ? padAddress(from) : padAddress(tx.from),
      })
    ),
    ...newFeePaymentAssets.map(addFeePaymentAsset),
    ...dispatchAsSell.map(dispatchSell),
    ...createPoolsWithPegs.map(createPoolWithPegs),
    ...stableswapAddLiquidityAs.map(sswapAddLiquidityAs),
  ];

  const extrinsic = utility.batchAll(batch);

  if (whitelist) {
    const whitelistedCall = extrinsic.method;
    const whitelist = api.tx.whitelist.whitelistCall(
      whitelistedCall.hash
    ).method;
    const proposal =
      api.tx.whitelist.dispatchWhitelistedCallWithPreimage(
        whitelistedCall
      ).method;
    const preimages = utility.batchAll([
      api.tx.preimage.notePreimage(whitelistedCall.toHex()),
      api.tx.preimage.notePreimage(proposal.toHex()),
    ]).method;
    return { whitelistedCall, preimages, whitelist, proposal };
  } else {
    return extrinsic.method;
  }
}

module.exports = {
  generateProposal,
};
