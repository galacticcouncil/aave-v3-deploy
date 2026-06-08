import 'dotenv/config';

export const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'https://rpc.nice.hydration.cloud',
  // signer only pays gas — pokeBorrow is permissionless, no role required.
  PRIVATE_KEY: process.env.PROPOSER_PRIVATE_KEY as `0x${string}`,
  SUBLOOP_ADDRESS: process.env.SUBLOOP_ADDRESS as `0x${string}`,
  // aave main-market pool, for leverage logging (defaults to lark-2 main market).
  POOL_ADDRESS: (process.env.POOL_ADDRESS ||
    '0x1b02E051683b5cfaC5929C25E84adb26ECf87B38') as `0x${string}`,
  POLL_INTERVAL_MS: Number(process.env.POLL_INTERVAL_MS || 30000),
  // idle once HF is within this fraction above target — avoids burning gas on
  // borrow-to-floor no-ops. e.g. 0.005 = stop ramping at HF ≤ target·1.005.
  RAMP_HF_BUFFER: Number(process.env.RAMP_HF_BUFFER || 0.005),
  ALERT_WEBHOOK: process.env.ALERT_WEBHOOK,
};
