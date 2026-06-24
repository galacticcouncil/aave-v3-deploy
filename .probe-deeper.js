const { ApiPromise, WsProvider } = require('@polkadot/api');
(async () => {
  const api = await ApiPromise.create({ provider: new WsProvider('wss://2.lark.hydration.cloud') });
  const meta = api.runtimeMetadata.asLatest;
  console.log('=== ALL PALLETS (filtered by relevance) ===');
  for (const p of meta.pallets) {
    const n = p.name.toString();
    if (/Giga|Hdx|Hollar|Fee|Liquid|Aave/i.test(n)) console.log('  ' + n);
  }
  console.log('\n=== gigaHdx storage entries ===');
  const giga = meta.pallets.find(p => p.name.toString() === 'GigaHdx');
  if (giga && giga.storage.isSome) {
    for (const s of giga.storage.unwrap().items) console.log('  ' + s.name.toString());
  }
  console.log('\n=== gigaHdx calls (extrinsics) ===');
  const callsType = giga.calls.unwrap().type;
  const callMeta = meta.lookup.getSiType(callsType);
  for (const v of callMeta.def.asVariant.variants) {
    console.log('  ' + v.name.toString() + '(' + v.fields.map(f => f.typeName.toString()).join(', ') + ')');
  }
  console.log('\n=== JS API decorated names (api.query.gigaHdx.*) ===');
  if (api.query.gigaHdx) console.log('  storages: ' + Object.keys(api.query.gigaHdx).join(', '));
  console.log('=== api.tx.gigaHdx.* ===');
  if (api.tx.gigaHdx) console.log('  extrinsics: ' + Object.keys(api.tx.gigaHdx).join(', '));
  await api.disconnect();
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
