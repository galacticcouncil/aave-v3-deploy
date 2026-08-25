const { ApiPromise, WsProvider, Keyring } = require('@polkadot/api');
(async () => {
  const api = await ApiPromise.create({ provider: new WsProvider('wss://2.lark.hydration.cloud') });

  // 1. Pallet inventory — confirm gigahdx is present
  const meta = api.runtimeMetadata.asLatest;
  const palletNames = meta.pallets.map(p => p.name.toString());
  const wantedPallets = ['Gigahdx', 'GigaHdx', 'GigahdxVoting', 'GigaHdxVoting', 'FeeProcessor', 'Liquidation'];
  console.log('=== PALLET CHECK ===');
  for (const p of wantedPallets) {
    console.log(`  ${palletNames.includes(p) ? '✓' : '✗'} ${p}`);
  }

  // 2. Confirm new home of gigaHdxPoolContract
  console.log('\n=== STORAGE CHECK ===');
  try {
    const v = await api.query.gigahdx.gigaHdxPoolContract();
    console.log(`  ✓ gigahdx.gigaHdxPoolContract → ${v.toString()}`);
  } catch (e) {
    console.log(`  ✗ gigahdx.gigaHdxPoolContract MISSING: ${e.message}`);
  }
  try {
    const v = await api.query.liquidation.gigaHdxPoolContract();
    console.log(`  (legacy) liquidation.gigaHdxPoolContract → ${v.toString()} (should NOT exist if pivot is fully landed)`);
  } catch (e) {
    console.log(`  ✓ liquidation.gigaHdxPoolContract removed (expected post-pivot): ${e.message.split('\n')[0]}`);
  }

  // 3. Confirm extrinsic location
  console.log('\n=== EXTRINSIC CHECK ===');
  console.log(`  ${typeof api.tx.gigahdx?.setGigahdxPoolContract === 'function' ? '✓' : '✗'} api.tx.gigahdx.setGigahdxPoolContract`);
  console.log(`  ${typeof api.tx.liquidation?.setGigahdxPoolContract === 'function' ? '(legacy still present)' : '✓ legacy removed'} api.tx.liquidation.setGigahdxPoolContract`);

  // 4. Spec version
  console.log('\n=== RUNTIME VERSION ===');
  const ver = api.runtimeVersion;
  console.log(`  spec: ${ver.specName} v${ver.specVersion}`);

  // 5. Alice WETH balance (asset 20)
  console.log('\n=== ALICE WETH ===');
  const alice = new Keyring({ type: 'sr25519' }).addFromUri('//Alice');
  const w = await api.query.tokens.accounts(alice.address, 20);
  console.log(`  Alice (${alice.address}): WETH free=${w.free.toString()} reserved=${w.reserved.toString()} frozen=${w.frozen.toString()}`);

  // 6. Alice HDX balance
  const acct = await api.query.system.account(alice.address);
  console.log(`  Alice HDX free=${acct.data.free.toString()} frozen=${acct.data.frozen.toString()}`);

  // 7. Total HDX issuance
  const ti = await api.query.balances.totalIssuance();
  console.log(`\n=== TOTAL HDX ISSUANCE ===\n  ${ti.toString()}`);

  await api.disconnect();
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
