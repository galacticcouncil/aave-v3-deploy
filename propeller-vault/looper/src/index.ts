import { PropellerLooper } from './looper.js';
import { CONFIG } from './config.js';

async function main() {
  console.log('Starting Propeller Looper...');
  console.log(`SubLoop: ${CONFIG.SUBLOOP_ADDRESS}`);
  console.log(`Poll interval: ${CONFIG.POLL_INTERVAL_MS}ms`);

  const looper = new PropellerLooper();

  const run = async () => {
    try {
      await looper.runCycle();
    } catch (err) {
      console.error('Looper cycle failed:', err);
    }
  };

  await run(); // run immediately
  setInterval(run, CONFIG.POLL_INTERVAL_MS);
}

main().catch(console.error);
