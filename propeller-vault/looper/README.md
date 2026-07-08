# Propeller Looper

Off-chain loop that ramps the shared `SubLoop` to its target health factor.

## Why it exists

The deploy/unwind legs dropped the pallet-DCA dependency — `pokeBorrow()` now
levers in a tranche **synchronously** (router sell, oracle-fair `minOut`) instead
of feeding a gradual DCA order. The gradualness that DCA used to provide now comes
from calling `pokeBorrow()` repeatedly off-chain. That's this bot.

`pokeBorrow()` is **permissionless** and fully bounded by the contract:

- borrows only down to `deployHfFloor` (= target HF) — can't over-lever,
- per-call amount capped at `deployTranche`,
- HOLLAR→aPRIME swap uses an Aave-oracle `minOut` — no sandwich value.

So the signer needs **no role** — only enough HDX to pay gas. A caller can only
advance the ramp or waste their own gas on a no-op at floor.

> `harvest()` / `pokeRepay()` / `deLever()` remain `KEEPER_ROLE` (harvest pays
> `msg.sender`). This bot is **ramp-only** and never calls them.

## Loop

Each cycle (`POLL_INTERVAL_MS`, default 30s):

```
read HF, targetHf
  ├─ HF ≤ target·(1+RAMP_HF_BUFFER)  ──▶ idle (already at target)
  └─ otherwise                       ──▶ pokeBorrow()  (lever one tranche)
```

## Run

Local:

```sh
npm install
SUBLOOP_ADDRESS=0x… LOOPER_PRIVATE_KEY=0x… RPC_URL=https://… npm start
```

Swarm:

```sh
docker stack deploy -c docker-stack.yml propeller-looper
```

See `docker-stack.yml` for the full env list. Keep `replicas: 1` — two loopers
would collide on the signer's tx nonce.
