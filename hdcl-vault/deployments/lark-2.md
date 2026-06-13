# BIL Vault — Deployment on `2.lark.hydration.cloud`

**Date:** 2026-05-20
**Commit:** `555abc7` (`feat/bil-vault`)
**Network:** Hydration lark testnet (`2.lark.hydration.cloud`, chain id 222222)
**Status:** Live and keeper-attended. UI development can target this.

---

## Addresses

| Contract | Address | Notes |
|---|---|---|
| **Vault (proxy)** | `0xbDAFEB92440d8696d6C143bc7e6B086d461e3502` | Canonical entry-point — UI integrates here |
| Vault impl | `0x45e10B05c6504Db3941366FC70B23DAEB0942F28` | UUPS implementation; behind proxy |
| QueueLib | `0xbd22a4a1a0941a9f5da0c6eb92d45f3009a11e3c` | Library — referenced by impl bytecode |
| BILOracle | `0x8DFD81241E0fDc06A05AB9f8f6E3eeCba6CC93Fa` | Chainlink-compatible 8-decimal feed |
| HOLLAR (underlying) | `0x531a654d1696ED52e7275A8cede955E82620f99a` | Existing Hydration HOLLAR token |
| Decentral Pool | `0x207a626c07b73E76134177D1f44B0f32e94ADB5a` | Initial / active deposit pool |
| Pool NFT (PoolToken) | `0xC91808c129C9766b13D22c9f0cD53Db459c0bc48` | NFTs minted to vault on each Decentral deposit |

---

## Roles

All roles currently granted to Alice (`0x222222B60cA97a4998B7D07b99034Fa4d9339531`) for testnet convenience. On mainnet these would be distinct addresses per `DEPLOYMENT.md`.

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Alice |
| `ADMIN_ROLE` | Alice |
| `UPGRADER_ROLE` | Alice |
| `GUARDIAN_ROLE` | Alice |
| `CLAIM_OPERATOR_ROLE` | Alice (= keeper bot address) |

---

## On-chain state at deploy time

| Field | Value | Notes |
|---|---|---|
| `totalSupply()` | `100000000000000000000` (100 hDCL) | Seed deposit minted |
| `totalAssets()` | `100000000000000000000` (100 HOLLAR equiv.) | Backed by 1 Decentral position |
| `exchangeRate()` | `1000000000000000000` (1.0e18) | Initial 1:1 |
| `getPositionCount()` | `1` | Seed position |
| `tvlCap()` | `2000000000000000000000000` (2M HOLLAR) | Deploy default |
| `minReinvestAmount()` | `10000000000000000000` (10 HOLLAR) | Floor below which reinvest is skipped |
| `minRedeemAmount()` | `1000000000000000000` (1 hDCL) | Per-request floor |
| `depositsPaused()` | `false` | Open for deposits |

---

## Keeper

Running on the lark Docker Swarm cluster as stack `bil-keeper`, service `bil-keeper_keeper`. Manageable via swarmpit at https://swarmpit.lark.hydration.cloud.

| | |
|---|---|
| Image | `galacticcouncil/bil-keeper:555abc7` (Docker Hub) |
| Replicas | 1 (single-replica enforced — shared key, no nonce race) |
| Poll interval | 12 s |
| Restart policy | `condition: any`, unbounded attempts |

Cycles every 12 s. Calls `pokeDecentral` on matured positions, `pokeQueue` after, and auto-claims for users who opted into `setAutoClaim(true)`.

**Stack file** (committed at `keeper/docker-stack.yml`):
```sh
# To redeploy with updated env or image:
docker stack deploy -c bil-vault/keeper/docker-stack.yml bil-keeper
```

**During UI dev workflows that send admin txs from the same key** (e.g. running `script/e2e-test.ts`): scale the keeper to 0 to avoid nonce races, then restore. See "Useful one-liners" below.

---

## RPC for UI

| Use | Endpoint |
|---|---|
| HTTPS RPC | `https://2.lark.hydration.cloud` |
| WSS RPC | `wss://2.lark.hydration.cloud` |
| Chain ID | `222222` |
| Native currency | HDX (parachain native), WETH (EVM-side gas) |
| Gas price guidance | `1500000` wei (0.0015 gwei) — matches deploy script |

Hydration's EVM runs in legacy (type-0) tx mode. **Don't send EIP-1559 (type-2) transactions** — they'll be rejected.

---

## Key contract surface for UI

### ERC-4626 deposit

```solidity
function deposit(uint256 assets, address receiver) returns (uint256 shares);
function mint(uint256 shares, address receiver) returns (uint256 assets);
function previewDeposit(uint256 assets) view returns (uint256 shares);
function previewMint(uint256 shares) view returns (uint256 assets);
```

`previewDeposit` reverts (`ZeroAmount` / `DepositTooSmall` / `VaultEmpty`) on inputs where deposit would revert. Does NOT honor `depositsPaused` or `tvlCap`.

### ERC-7540 async redeem

```solidity
function requestRedeem(uint256 shares, address controller, address owner) returns (uint256 requestId);
function cancelRedeem(uint256 requestId);                   // refunds unsettled portion
function redeem(uint256 shares, address receiver, address controller) returns (uint256 assets);
function withdraw(uint256 assets, address receiver, address controller) returns (uint256 shares);
function pendingRedeemRequest(uint256 reqId, address controller) view returns (uint256);
function claimableRedeemRequest(uint256 reqId, address controller) view returns (uint256);
function maxRedeem(address controller) view returns (uint256);     // total settled-but-unclaimed shares
function maxWithdraw(address controller) view returns (uint256);   // total settled-but-unclaimed HOLLAR
```

### Operator + auto-claim

```solidity
function setOperator(address operator, bool approved);              // per-user approval
function isOperator(address controller, address operator) view returns (bool);
function setAutoClaim(bool enabled);                                // opt into keeper-initiated claim
function autoClaimEnabled(address controller) view returns (bool);
```

### Vault state views

```solidity
function totalAssets() view returns (uint256);                       // HOLLAR equivalent
function exchangeRate() view returns (uint256);                      // 1e18-scaled
function getRedemptionRequest(uint256 reqId) view returns (
    address user, uint256 bilAmount, uint256 bilSettled, uint256 hollarOwed, bool active
);
function getPosition(uint256 idx) view returns (
    uint256 tokenId, uint256 principal, uint256 apyWad,
    uint256 depositTime, uint256 maturityTime, uint8 state
);
function getEstimatedWaitTime(uint256 reqId) view returns (uint256 estimatedSeconds);
```

### Events to index

- `Deposit(sender, owner, assets, shares)` — canonical ERC-4626
- `Deposited(user, hollarAmount, bilMinted, tokenId)` — vault-specific
- `RedeemRequest(controller, owner, requestId, sender, shares)` — ERC-7540 canonical
- `RedemptionRequested(requestId, user, bilAmount)` — vault-specific
- `RedemptionFulfilled(requestId, user, hollarAmount, bilBurned)` — full settle
- `RedemptionPartiallyFulfilled(...)` — partial settle
- `RedemptionCancelled(requestId, bilReturned)`
- `Withdraw(sender, receiver, owner, assets, shares)` — canonical ERC-4626/7540 claim
- `OperatorSet(controller, operator, approved)`
- `AutoClaimSet(controller, enabled)`
- `PositionProcessed(positionIndex, tokenId, newState)`
- `PositionRedeemed(positionIndex, tokenId, yieldReceived, principalReceived)`

---

## Workflow for UI dev / smoke testing

### Deposit flow
1. `hollar.approve(vault, amount)` — standard ERC-20
2. `vault.deposit(amount, user)` → returns `shares`
3. UI shows `vault.balanceOf(user)` and `vault.exchangeRate()`

### Redeem flow (no auto-claim)
1. `vault.requestRedeem(shares, user, user)` → returns `requestId`
2. UI polls `vault.pendingRedeemRequest(reqId, user)` and `vault.claimableRedeemRequest(reqId, user)`
3. Once `claimable > 0`, user clicks Claim → `vault.redeem(claimable, user, user)` → HOLLAR arrives

### Redeem flow (auto-claim opt-in)
1. (once) `vault.setAutoClaim(true)`
2. `vault.requestRedeem(...)`
3. UI shows pending → claimable → HOLLAR arrives (keeper triggers the `redeem` automatically)

### Cancel flow
- `vault.cancelRedeem(reqId)` — refunds the still-unsettled portion; settled portion stays as a claim

### Time scales on lark
- Decentral pool's minimum investment period: 60 days (then yield withdrawal available)
- Principal withdrawal delay: 48 hours after request
- Realistically the UI on lark can demonstrate deposit + cancel + view flows immediately, but the full redeem cycle requires waiting on Decentral's timers (or admin warping if you have lark control)

---

## Useful one-liners

```sh
# Status snapshot
cast call 0xbDAFEB92440d8696d6C143bc7e6B086d461e3502 'exchangeRate()(uint256)' --rpc-url https://2.lark.hydration.cloud

# Keeper management (via swarmpit at https://swarmpit.lark.hydration.cloud)
#   Service ID: bil-keeper_keeper   |   Stack: bil-keeper
#   View logs / scale / restart in the UI, OR via the swarmpit-lark MCP tools.

# Toggle auto-claim for a user (Alice's key)
cast send --rpc-url https://2.lark.hydration.cloud --private-key <PK> --legacy --gas-price 1500000 \
  0xbDAFEB92440d8696d6C143bc7e6B086d461e3502 'setAutoClaim(bool)' true

# Manually trigger a keeper cycle (in case the bot is paused)
cast send --rpc-url https://2.lark.hydration.cloud --private-key <PK> --legacy --gas-price 1500000 \
  0xbDAFEB92440d8696d6C143bc7e6B086d461e3502 'pokeQueue()'
```

---

## Known testnet caveats

- Single-key everything (Alice is admin + guardian + claim-operator). Mainnet will use distinct addresses.
- Decentral pool on lark may have shorter or different timing parameters than mainnet; check `pool.minimumInvestmentPeriodSeconds()` and `pool.principalWithdrawalDelaySeconds()` if you need exact numbers.
- The lark testnet is periodically reset. After a reset, run `script/deploy-lark.sh` again, repeat the role grants + seed steps in this doc, and restart the keeper container with the new `VAULT_ADDRESS`.
