import 'dotenv/config';

export const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'https://rpc.nice.hydration.cloud',
  PRIVATE_KEY: process.env.KEEPER_PRIVATE_KEY as `0x${string}`,
  VAULT_ADDRESS: process.env.VAULT_ADDRESS as `0x${string}`,
  POLL_INTERVAL_MS: Number(process.env.POLL_INTERVAL_MS || 6000),
  STALE_THRESHOLD_SECONDS: 96 * 3600,
  ALERT_WEBHOOK: process.env.ALERT_WEBHOOK,
};
