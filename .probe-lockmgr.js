const { ethers } = require("ethers");
(async () => {
  const p = new ethers.providers.JsonRpcProvider("https://2.lark.hydration.cloud");
  const STHDX_ATOKEN = "0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661";
  const LOCK_MGR = "0x0000000000000000000000000000000000000806";
  const BOB = "0x..."; // we'll compute
  // just call from a dummy account. Use Alice's EVM-mapped address (deployer for simplicity)
  const DEPLOYER = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";

  // Direct precompile call: getLockedBalance(token, account)
  const iface = new ethers.utils.Interface([
    "function getLockedBalance(address token, address account) view returns (uint256)",
  ]);
  const data = iface.encodeFunctionData("getLockedBalance", [STHDX_ATOKEN, DEPLOYER]);
  console.log("Direct precompile call: getLockedBalance(stHDX_aToken, deployer)");
  try {
    const r = await p.call({ to: LOCK_MGR, data });
    console.log("  raw:", r);
    const decoded = iface.decodeFunctionResult("getLockedBalance", r);
    console.log("  decoded locked:", decoded[0].toString());
  } catch (e) {
    console.log("  REVERTS:", e.message.slice(0, 200));
  }

  // Also: aToken.getFreeBalance
  const aIface = new ethers.utils.Interface([
    "function getFreeBalance(address account) view returns (uint256)",
    "function getLockedBalance(address account) view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
  ]);
  console.log("\naToken.getFreeBalance(deployer):");
  try {
    const r = await p.call({ to: STHDX_ATOKEN, data: aIface.encodeFunctionData("getFreeBalance", [DEPLOYER]) });
    console.log("  raw:", r);
    const decoded = aIface.decodeFunctionResult("getFreeBalance", r);
    console.log("  decoded:", decoded[0].toString());
  } catch (e) {
    console.log("  REVERTS:", e.message.slice(0, 200));
  }

  console.log("\naToken.getLockedBalance(deployer):");
  try {
    const r = await p.call({ to: STHDX_ATOKEN, data: aIface.encodeFunctionData("getLockedBalance", [DEPLOYER]) });
    console.log("  raw:", r);
    const decoded = aIface.decodeFunctionResult("getLockedBalance", r);
    console.log("  decoded:", decoded[0].toString());
  } catch (e) {
    console.log("  REVERTS:", e.message.slice(0, 200));
  }
})();
