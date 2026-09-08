# Propeller Deployments

One file per active deployment, kept current with the on-chain state.

| Network | File | Vault Addresses | Status |
|---|---|---|---|
| Hydration **lark-4** (`4.lark.hydration.cloud`, chain `222222`) | [lark-4.md](./lark-4.md) | pETH `0x3645E7013C00d91D9E6c3EA3847E586967d8fc67` · ptBTC `0x22fff20f7f4a7047f6975248aeafc2f013ae76cf` | Live 2026-09-07, 78/78 pre-ramp · 79/80 post-ramp, deposit + full ramp proven |
| Hydration **mainnet** | _(not yet deployed)_ | — | Pending external audit + governance sign-off |

## For UI / integrator teams

Pick the file matching your target network. Each contains: contract addresses, role
assignments, current on-chain config, RPC endpoints, the function surface to integrate
against, the events to index, and worked example flows.

## Conventions

- **Lark testnets are reset periodically.** After a reset the deployment file is updated with
  new addresses by re-running the Step 1 scripts in `../DEPLOYMENT.md`. Pin to this file rather
  than copy-pasting addresses into UI config.
- The keeper (`propeller-looper`) runs on the lark Docker Swarm cluster. The protocol works
  without it — every poke is permissionless — but nothing *progresses* without someone calling
  them: the loop never ramps, redemptions never settle, and carry is never realised.
- **Always run `scripts/propeller/verify-readiness.ts` after a deploy or a governance change**,
  and paste its summary line into the deployment file. `dispatchAsAaveManager` reports EVM
  reverts as events, not extrinsic failures, so a referendum can enact with calls silently
  reverted.
- See `../DEPLOYMENT.md` for the full procedure and `../../PROPELLER-MAINNET-HANDOVER.md` for
  what has already gone wrong and how to avoid repeating it.
