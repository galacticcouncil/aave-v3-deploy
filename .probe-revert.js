const { ethers } = require("ethers");
(async () => {
  const p = new ethers.providers.JsonRpcProvider("https://2.lark.hydration.cloud");
  const STHDX_ATOKEN = "0x25fA2B5a75ECDF39BA194fc96AAc12682DB42661";
  const POOL = "0xb952AE92cC4D8D703d2d71Ab541baB34c94b944A";
  const STHDX_PRECOMPILE = "0x000000000000000000000000000000010000029e";

  // //Bob: pubkey 0x8eaf04151687736326c9fea17e25fc5287613693c912909cb226aa4794f26a48
  // //Alice: pubkey 0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d
  const bobEvm = "0x8eaf04151687736326c9fea17e25fc5287613693";
  const aliceEvm = "0xd43593c715fdd31c61141abd04a99fd6822c8558";

  const erc20 = new ethers.utils.Interface([
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address,uint256) returns (bool)",
  ]);
  const balRaw = await p.call({ to: STHDX_ATOKEN, data: erc20.encodeFunctionData("balanceOf", [bobEvm]) });
  const bal = ethers.BigNumber.from(balRaw);
  console.log(`Bob aGIGAHDXstHDX balance: ${bal.toString()}`);

  console.log("\nSimulating aToken.transfer(Alice, bal/100) from Bob:");
  try {
    const r = await p.call({ from: bobEvm, to: STHDX_ATOKEN, data: erc20.encodeFunctionData("transfer", [aliceEvm, bal.div(100)]) });
    console.log("  returned:", r);
  } catch (e) {
    const msg = e.error?.body || e.body || e.message;
    console.log("  REVERT:", msg.slice(0, 600));
  }

  console.log("\nSimulating Pool.withdraw(stHDX, bal/10, Bob) from Bob:");
  const poolIface = new ethers.utils.Interface([
    "function withdraw(address,uint256,address) returns (uint256)",
  ]);
  try {
    const r = await p.call({ from: bobEvm, to: POOL, data: poolIface.encodeFunctionData("withdraw", [STHDX_PRECOMPILE, bal.div(10), bobEvm]) });
    console.log("  returned:", r);
  } catch (e) {
    const msg = e.error?.body || e.body || e.message;
    console.log("  REVERT:", msg.slice(0, 600));
  }

  // Also: directly call aToken.burn through Pool? burn is onlyPool, can't simulate from Bob.
  // But check: does aToken's _underlyingAsset match the precompile?
  const aIface = new ethers.utils.Interface([
    "function UNDERLYING_ASSET_ADDRESS() view returns (address)",
    "function POOL() view returns (address)",
  ]);
  try {
    const r = await p.call({ to: STHDX_ATOKEN, data: aIface.encodeFunctionData("UNDERLYING_ASSET_ADDRESS", []) });
    console.log("\naToken UNDERLYING_ASSET:", "0x" + r.slice(26));
  } catch (e) { console.log("  err:", e.message.slice(0,100)); }
  try {
    const r = await p.call({ to: STHDX_ATOKEN, data: aIface.encodeFunctionData("POOL", []) });
    console.log("aToken POOL:           ", "0x" + r.slice(26));
  } catch (e) { console.log("  err:", e.message.slice(0,100)); }

  // Bob's actual stHDX precompile balance (does Bob have any?)
  try {
    const r = await p.call({ to: STHDX_PRECOMPILE, data: erc20.encodeFunctionData("balanceOf", [bobEvm]) });
    console.log(`\nBob stHDX (precompile) balance: ${ethers.BigNumber.from(r).toString()}`);
  } catch (e) { console.log("  err:", e.message.slice(0,100)); }
  try {
    const r = await p.call({ to: STHDX_PRECOMPILE, data: erc20.encodeFunctionData("balanceOf", [STHDX_ATOKEN]) });
    console.log(`aToken stHDX (precompile) balance: ${ethers.BigNumber.from(r).toString()}`);
  } catch (e) { console.log("  err:", e.message.slice(0,100)); }
})();
