# BIL Vault Deployments

One file per active deployment, kept current with the on-chain state.

| Network | File | Vault Address | Status |
|---|---|---|---|
| Hydration **lark testnet** (`2.lark.hydration.cloud`, chain `222222`) | [lark-2.md](./lark-2.md) | [`0xbDAFEB92440d8696d6C143bc7e6B086d461e3502`](https://2.lark.hydration.cloud) | Live, keeper-attended, UI-ready |
| Hydration **mainnet** | _(not yet deployed)_ | — | Pending governance sign-off + final audit pass |

## For UI / integrator teams

Pick the file matching your target network. Each contains: contract addresses (vault, library, oracle, underlying HOLLAR, Decentral pool, pool NFT), role assignments, current on-chain config (TVL cap, min-amounts), RPC endpoints, the ERC-4626 + ERC-7540 function surface, the event list to index, and worked example flows (deposit / redeem / cancel / auto-claim).

## Conventions

- **Lark testnet is reset periodically.** After a reset, the deployment file is updated with new addresses by re-running `script/deploy-lark.sh`. Treat the addresses as stable for the duration of a given lark generation, but expect them to change between resets — pin to the `lark-2.md` file rather than copy-pasting addresses into UI config.
- The keeper bot runs at `swarmpit.lark.hydration.cloud` as stack `bil-keeper`. The vault works without the keeper (everything is still callable), but auto-claim and timely settlement depend on it.
- See `../DEPLOYMENT.md` for the procedure to bring up a fresh deployment from scratch.
