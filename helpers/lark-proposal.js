const { getApi } = require('./hydration-proposal.js');

/**
 * Lark-compatible aaveManagerCall.
 * Lark's evm.call has 10 args (added authorizationList for EIP-7702).
 */
async function aaveManagerCall({
  from,
  to,
  data,
  gasLimit = "600000",
  gasPrice = "600000000",
}) {
  return (await getApi()).tx.dispatcher.dispatchAsAaveManager(
    (await getApi()).tx.evm.call(
      from,
      to,
      data,
      "0",
      gasLimit.toString(),
      gasPrice,
      undefined,
      undefined,
      [],
      []
    )
  );
}

module.exports = { aaveManagerCall };
