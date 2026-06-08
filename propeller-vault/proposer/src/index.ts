import { PropellerProposer } from './proposer.js';
import { CONFIG } from './config.js';

async function main() {
  console.log('Starting Propeller Proposer...');
  console.log(`SubLoop: ${CONFIG.SUBLOOP_ADDRESS}`);
  console.log(`Poll interval: ${CONFIG.POLL_INTERVAL_MS}ms`);

  const proposer = new PropellerProposer();

  const run = async () => {
    try {
      await proposer.runCycle();
    } catch (err) {
      console.error('Proposer cycle failed:', err);
    }
  };

  await run(); // run immediately
  setInterval(run, CONFIG.POLL_INTERVAL_MS);
}

main().catch(console.error);
