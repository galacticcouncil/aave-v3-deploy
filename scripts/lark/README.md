# Lark testnet helpers

Operational scripts for running, configuring, and verifying the GIGAHDX deployment on Hydration's `lark2` test chain. Mainnet uses the `gigahdx-launch` hardhat task instead — these scripts are testnet-only.

All scripts default to `wss://2.lark.hydration.cloud` / `https://2.lark.hydration.cloud` and Alice (`//Alice`) as the sole TC member. Override via `WS_URL` / `RPC_URL` / `PRIV_KEY` env vars.

## Deployment sequence (cold start on a fresh lark2)

```bash
# 1. Allow our deployer EVM key on the chain
ts-node scripts/lark/whitelist-deployer.ts

# 2. Fund the deployer with HDX
ts-node scripts/lark/fund-account.ts

# 3. Deploy core + GIGAHDX market
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=lark2 npx hardhat deploy --tags market

# 4. Deploy LockableAToken impl + FixedPriceOracle for stHDX
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=lark2 npx hardhat deploy-LockableAToken
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=lark2 \
  npx hardhat deploy-FixedPriceOracle --asset stHDX --price 2500000

# 5. Move admin roles to gov precompile (0xaa7e…)
HARDHAT_NETWORK=lark2 npx hardhat run scripts/lark/transfer-admin-to-governance.ts

# 6. Wire up stHDX oracle via TC referendum
ts-node scripts/lark/set-sthdx-oracle.ts

# 7. Submit the GIGAHDX init proposal via TC referendum
ts-node scripts/lark/submit-gigahdx-proposal.ts

# 8. Point the runtime's GIGAHDX adapter at the new pool
ts-node scripts/lark/set-gigahdx-pool.ts

# 9. Sanity check the whole thing
ts-node scripts/lark/generate-addresses.ts        # writes deployments/lark2/_addresses.{json,md}
ts-node scripts/lark/verify-readiness.ts          # PASS/FAIL table

# 10. End-to-end smoke test
ts-node scripts/lark/test-e2e.ts
```

## Other helpers

- `runtime-upgrade.ts` — apply a new runtime WASM via the whitelisted_caller track (50k HDX deposit).
- `refer-whitelist.ts` — generic "TC-whitelist + Alice-vote-through" pipeline used when a one-off privileged call is needed.
- `mint-weth-wl.ts` — populate WETH balances on a fresh chain when `tokens.setBalance` is needed instead of `currencies.transfer`.
- `check-alice.ts`, `check-governance.ts`, `check-parameters.ts` — read-only pre-flight checks.
- `grant-risk-admin.ts` — manual ACL fix when `configureReservesByHelper` skips the admin grant on lark.
- `test-gigastake-routing.ts` — exercise the gigastake → liquidation flow.
- `verify-hollar-layering.ts` — assert HOLLAR's per-MM aToken layering.

## Why these are scripts, not hardhat tasks

The lark scripts intentionally bypass `generateProposalV2` and submit raw substrate calls one at a time. With Alice as the only TC member, this is dramatically faster than going through the full preimage/decoder pipeline that `tasks/proposals/gigahdx-launch.ts` uses for mainnet. For the same reason, do **not** copy this pattern to mainnet — mainnet must go through proper governance.
