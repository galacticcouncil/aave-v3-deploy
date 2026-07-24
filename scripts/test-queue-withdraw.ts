// End-to-end test of the queue-withdraw fix: submit the same two EVM calls
// the fixed UI now builds — pool.withdraw(BIL underlying) then
// vault.requestRedeem(shares) — using Alice's hardhat signer. Validates that:
//   1. pool.withdraw with BIL precompile (0x…00000226) succeeds (was reverting
//      pre-fix when the UI used the BIL aToken precompile 0x…00000037)
//   2. vault.requestRedeem queues a redemption entry on the substrate side
//
// Usage:
//   MARKET_NAME=BIL HARDHAT_NETWORK=lark2 \
//     npx hardhat run scripts/test-queue-withdraw.ts --network lark2

import hre from "hardhat";

const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const DCL_PRECOMPILE = "0x0000000000000000000000000000000100000226";
// Small enough to stay above HF=1 on the looper position. Alice has 32K BIL
// at $1.0082, $25.8K debt; pulling 100 BIL keeps HF > 1.05.
const BIL_WITHDRAW = 100n * 10n ** 18n;

async function main() {
  const hhre = hre as any;
  const eth = hhre.ethers;
  const { deployer } = await hhre.getNamedAccounts();
  const me = await eth.getSigner(deployer);
  const meAddr = await me.getAddress();
  console.log(`acting as ${meAddr}`);

  const pool = await eth.getContractAt(
    [
      "function getUserAccountData(address) view returns (uint256 totalCollateralBase,uint256 totalDebtBase,uint256 availableBorrowsBase,uint256 currentLiquidationThreshold,uint256 ltv,uint256 healthFactor)",
      "function withdraw(address asset, uint256 amount, address to) returns (uint256)",
    ],
    (await hhre.deployments.get("Pool-Proxy-BIL")).address
  );
  const vault = await eth.getContractAt(
    [
      "function balanceOf(address) view returns (uint256)",
      "function requestRedeem(uint256 shares, address controller, address owner) returns (uint256 requestId)",
      "function getRedemptionQueueLength() view returns (uint256)",
    ],
    (await hhre.deployments.get("BILOracleAdapter") /* read vault from adapter */)
      .address
  );
  // Resolve real vault proxy via the oracle adapter.
  const vaultAddr = await (
    await eth.getContractAt(
      ["function vault() view returns (address)"],
      (await hhre.deployments.get("BILOracleAdapter")).address
    )
  ).vault();
  const vaultC = await eth.getContractAt(
    [
      "function balanceOf(address) view returns (uint256)",
      "function requestRedeem(uint256 shares, address controller, address owner) returns (uint256 requestId)",
      "function getRedemptionQueueLength() view returns (uint256)",
    ],
    vaultAddr,
    me
  );

  // Pre-state ----------------------------------------------------------------
  const before = await pool.getUserAccountData(meAddr);
  const queueLenBefore = (await vaultC.getRedemptionQueueLength()).toBigInt();
  const vaultBalBefore = (await vaultC.balanceOf(meAddr)).toBigInt();
  console.log(`\nBEFORE:`);
  console.log(`  collateral USD : ${Number(before.totalCollateralBase) / 1e8}`);
  console.log(`  debt USD       : ${Number(before.totalDebtBase) / 1e8}`);
  console.log(`  HF             : ${Number(before.healthFactor) / 1e18}`);
  console.log(`  raw BIL bal   : ${vaultBalBefore / 10n ** 18n}`);
  console.log(`  queue length   : ${queueLenBefore}`);

  // Nonce mgmt — hardhat-deploy + ethers v5 race like in the looper.
  let nonce = await eth.provider.getTransactionCount(meAddr, "pending");

  // 1. pool.withdraw(BIL underlying, 100, me) — burns aBIL → raw BIL
  console.log(`\nstep 1: pool.withdraw(${DCL_PRECOMPILE}, ${BIL_WITHDRAW}, ${meAddr})`);
  const tx1 = await pool.connect(me).withdraw(
    DCL_PRECOMPILE,
    BIL_WITHDRAW,
    meAddr,
    { gasLimit: 1_500_000, nonce: nonce++ }
  );
  const r1 = await tx1.wait();
  console.log(`  tx ${r1.transactionHash} mined block ${r1.blockNumber} status=${r1.status}`);

  // 2. vault.requestRedeem(100, me, me) — queues a redemption
  console.log(`\nstep 2: vault.requestRedeem(${BIL_WITHDRAW}, ${meAddr}, ${meAddr})`);
  const tx2 = await vaultC.requestRedeem(BIL_WITHDRAW, meAddr, meAddr, {
    gasLimit: 2_000_000,
    nonce: nonce++,
  });
  const r2 = await tx2.wait();
  console.log(`  tx ${r2.transactionHash} mined block ${r2.blockNumber} status=${r2.status}`);

  // Post-state ---------------------------------------------------------------
  const after = await pool.getUserAccountData(meAddr);
  const queueLenAfter = (await vaultC.getRedemptionQueueLength()).toBigInt();
  const vaultBalAfter = (await vaultC.balanceOf(meAddr)).toBigInt();
  console.log(`\nAFTER:`);
  console.log(`  collateral USD : ${Number(after.totalCollateralBase) / 1e8}`);
  console.log(`  debt USD       : ${Number(after.totalDebtBase) / 1e8}`);
  console.log(`  HF             : ${Number(after.healthFactor) / 1e18}`);
  console.log(`  raw BIL bal   : ${vaultBalAfter / 10n ** 18n}`);
  console.log(`  queue length   : ${queueLenAfter} (Δ +${queueLenAfter - queueLenBefore})`);

  if (queueLenAfter > queueLenBefore) {
    console.log(`\n✅ queue withdraw end-to-end works — request enqueued`);
  } else {
    console.log(`\n❌ queue length unchanged — requestRedeem may have failed`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
