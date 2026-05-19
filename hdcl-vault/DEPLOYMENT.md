# HDCL Vault Deployment Plan

> Audience: deploy operator / Hydration governance facilitator
> Companion to: `script/Deploy.s.sol`, `PLAN-multi-pool.md`, `x-ray/entry-points.md`

The Foundry script handles the **on-chain** deployment (impl + proxy + initialize + oracle wiring). Everything below is the procedure for the rest of the lifecycle: roles, optional pools, keeper bootstrap, and seed.

---

## Step 0 — Pre-flight

Confirm before broadcasting:

| Item | Where | Sanity check |
|---|---|---|
| `DECENTRAL_POOL`, `POOL_TOKEN`, `HOLLAR` | `script/Deploy.s.sol:11-13` | Match the Decentral protocol's deployed addresses on Hydration |
| `TVL_CAP` | `script/Deploy.s.sol:14` | Match the agreed launch cap |
| `ADMIN_ADDRESS` env | broadcast | Hydration governance *economics-parameters* track multisig/contract |
| `PRIVATE_KEY` env (deployer) | broadcast | Must equal `ADMIN_ADDRESS` — the script wires oracle inline using admin-gated `setOracle`. The require() at `Deploy.s.sol:48` catches mismatch at deploy time. |

---

## Step 1 — Deploy via script

```sh
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --legacy
```

After success, the script logs three addresses:
- `Implementation` — UUPS impl contract (unused once proxied)
- `Proxy (HDCL Vault)` — the canonical vault address
- `WDCLOracle` — the Chainlink-compatible feed for Aave

Record all three. The proxy is the only one consumers should interact with.

**What `initialize` did automatically (from `HDCLVault.sol:348`):**
- Registered `DECENTRAL_POOL` and set it as `activeDepositPool` — **no separate `registerPool` / `setActiveDepositPool` calls needed for the seed pool**
- Set `tvlCap`, defaulted `minReinvestAmount = 10 HOLLAR`, `minRedeemAmount = 1 HDCL`
- Granted `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `UPGRADER_ROLE` to `_admin`

---

## Step 2 — Grant operational roles

`initialize` does **NOT** grant `GUARDIAN_ROLE` or `CLAIM_OPERATOR_ROLE`. The admin must grant these explicitly:

```solidity
// GUARDIAN_ROLE — fast pause/unpause (technical committee)
vault.grantRole(vault.GUARDIAN_ROLE(), HYDRATION_TECH_COMMITTEE);

// CLAIM_OPERATOR_ROLE — auto-claim on behalf of opted-in users.
// REQUIRED for the keeper bot's auto-claim loop to fire (see keeper/src/keeper.ts).
// If skipped: pull-redemption still works, but users must call redeem() themselves.
vault.grantRole(vault.CLAIM_OPERATOR_ROLE(), KEEPER_ADDRESS);
```

Verify with:

```solidity
vault.hasRole(vault.GUARDIAN_ROLE(), HYDRATION_TECH_COMMITTEE) == true
vault.hasRole(vault.CLAIM_OPERATOR_ROLE(), KEEPER_ADDRESS) == true
```

---

## Step 3 — Seed deposit

Per spec §9: seed a small initial deposit so the exchange rate is established at 1:1 (modulo `DEAD_SHARES = 1000` wei locked at `0xdead`).

```solidity
// As any address with HOLLAR; admin is fine.
hollar.approve(vault, SEED_AMOUNT);                    // e.g. 100 HOLLAR
vault.deposit(SEED_AMOUNT, ADMIN_ADDRESS);
```

Sanity:
- `vault.totalSupply() == SEED_AMOUNT - 1000` (the dead shares)
- `vault.exchangeRate() ≈ 1e18` (first deposit baseline)
- A position is created in the active deposit pool (verify via `vault.getPositionCount() == 1`)

---

## Step 4 — Bootstrap the keeper

The keeper requires:

| Env var | Value |
|---|---|
| `RPC_URL` | Hydration RPC |
| `VAULT_ADDRESS` | proxy address from Step 1 |
| `KEEPER_PRIVATE_KEY` | the private key whose address holds `CLAIM_OPERATOR_ROLE` (Step 2) |
| `ALERT_WEBHOOK` | optional — **Discord webhook URL** (`https://discord.com/api/webhooks/<id>/<token>`). Alerts post as richer embeds with yellow (warn) / red (error) sidebar coloring and the vault address in the footer. |

Verify before starting:
- Keeper address has gas (HDX) on Hydration
- `vault.hasRole(vault.CLAIM_OPERATOR_ROLE(), keeperAddress)` is `true`

Start with `npm start` from `hdcl-vault/keeper/`. First cycle logs should show `Positions: 1 (head: 0)` (the seed position) and no `pokeQueue` call yet.

---

## Step 5 (optional, post-launch) — Multi-pool

If multiple Decentral pools should accept deposits over time (e.g. a fresh Decentral cohort at a different APY launches):

```solidity
// 5a. Register the additional pool (validates pool ↔ poolToken pairing).
vault.registerPool(IDecentralPool(NEW_POOL_ADDRESS));

// 5b. (optional) Make it the new deposit target. Existing positions are
//     anchored to their origin pool via positionPool[i] and are untouched.
vault.setActiveDepositPool(IDecentralPool(NEW_POOL_ADDRESS));
```

To retire an old pool: drain it (let all positions mature & redeem naturally), then:

```solidity
vault.retirePool(IDecentralPool(OLD_POOL_ADDRESS));  // reverts if any non-Redeemed position is anchored to it
```

See `PLAN-multi-pool.md → "Pool rotation procedure"` for the full normal/emergency rotation flows.

---

## Step 6 — External consumers

Once the seed deposit is in and the oracle returns a positive answer, wire external consumers:

- **Aave**: register `WDCLOracle` as the price feed for the hDCL listing
- **UI / SDK**: point at the proxy address; ERC-4626 + ERC-7540 surface is available

---

## Rollback / abort paths

| Scenario | Action |
|---|---|
| Oracle wiring fails (`deploy` reverts at line 73-76) | Re-deploy — the failed proxy is unusable (init already consumed) |
| Seed deposit reverts | Investigate Decentral pool state (paused? min-investment changed?); fix and retry |
| Keeper can't auto-claim | Check `hasRole(CLAIM_OPERATOR_ROLE, keeperAddress)`; check at least one user has `autoClaimEnabled == true` |
| Wrong admin granted at init | Cannot rotate `DEFAULT_ADMIN_ROLE` away cleanly — accept and grant additional admins, or UUPS-upgrade with a re-init shim |

---

## Post-deploy invariants to confirm

Before declaring the deploy successful and announcing the vault:

1. `vault.totalAssets() > 0` and `vault.totalSupply() > 0`
2. `vault.exchangeRate()` ≈ 1e18 (±10 wei)
3. `vault.getOraclePrice() > 0`
4. `vault.getPoolCount() == 1` (seed pool only, unless multi-pool was set up in Step 5)
5. `vault.activeDepositPool() == DECENTRAL_POOL`
6. Keeper cycle runs without errors for ≥3 consecutive cycles
