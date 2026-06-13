import { BILKeeper } from './keeper.js';
import { CONFIG } from './config.js';

async function main() {
  console.log('Starting BIL Keeper...');
  console.log(`Vault: ${CONFIG.VAULT_ADDRESS}`);
  console.log(`Poll interval: ${CONFIG.POLL_INTERVAL_MS}ms`);

  const keeper = new BILKeeper();

  const run = async () => {
    try {
      await keeper.runCycle();
    } catch (err) {
      console.error('Keeper cycle failed:', err);
    }
  };

  await run(); // Run immediately
  setInterval(run, CONFIG.POLL_INTERVAL_MS);
}

main().catch(console.error);
