const { ethers } = require("ethers");
(async () => {
  const p = new ethers.providers.JsonRpcProvider("https://2.lark.hydration.cloud");
  const STHDX_ATOKEN = "0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661";
  const LOCK_MGR = "0x0000000000000000000000000000000000000806";
  const bobEvm = "0x8eaf04151687736326c9fea17e25fc5287613693";

  const a = new ethers.utils.Interface([
    "function balanceOf(address) view returns (uint256)",
    "function getFreeBalance(address) view returns (uint256)",
    "function getLockedBalance(address) view returns (uint256)",
  ]);
  const lm = new ethers.utils.Interface([
    "function getLockedBalance(address token, address account) view returns (uint256)",
  ]);

  const balRaw = await p.call({ to: STHDX_ATOKEN, data: a.encodeFunctionData("balanceOf", [bobEvm]) });
  console.log("aToken.balanceOf(Bob):       ", ethers.BigNumber.from(balRaw).toString());

  const freeRaw = await p.call({ to: STHDX_ATOKEN, data: a.encodeFunctionData("getFreeBalance", [bobEvm]) });
  console.log("aToken.getFreeBalance(Bob):  ", ethers.BigNumber.from(freeRaw).toString());

  const lockRaw = await p.call({ to: STHDX_ATOKEN, data: a.encodeFunctionData("getLockedBalance", [bobEvm]) });
  console.log("aToken.getLockedBalance(Bob):", ethers.BigNumber.from(lockRaw).toString());

  const directRaw = await p.call({ to: LOCK_MGR, data: lm.encodeFunctionData("getLockedBalance", [STHDX_ATOKEN, bobEvm]) });
  console.log("precompile getLockedBalance(aToken, Bob):", ethers.BigNumber.from(directRaw).toString());
})();
