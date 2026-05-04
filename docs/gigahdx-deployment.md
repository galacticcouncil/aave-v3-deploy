# GIGAHDX Deployment Plan

Second Aave V3 money market instance on Hydration.
- **stHDX** (asset 670, 12 decimals) — only collateral, LockableAToken
- **HOLLAR** (asset 222, 18 decimals) — only borrowable, GhoAToken facilitator
- GIGAHDX ≈ HDX ≈ stHDX price

## Runtime Compatibility (HydraDX-node)

The `feat/gigahdx-impl` and `feat/gigahdx-liquidation` branches introduce:

| Component | Purpose |
|---|---|
| `pallet-gigahdx` | Core staking: HDX → stHDX → supply to MM → GIGAHDX |
| `pallet-gigahdx-voting` | Conviction voting with GIGAHDX, lock enforcement via 0x0806 precompile |
| `pallet-fee-processor` | Fee distribution: 70% gigapot, 10% staking, 10% referrals |
| `pallet-liquidation` update | GIGAHDX liquidation: clear locks → treasury borrows HOLLAR → liquidationCall |
| LockManager precompile (0x0806) | Reads voting locks, enforced by LockableAToken |

### Runtime change needed for second pool

**Current state:** The runtime uses a single `BorrowingContract` storage value
(`pallet_liquidation::BorrowingContract`) pointing to the existing Hydration Market Pool proxy.
Both `AaveMoneyMarket` (supply/withdraw stHDX) and `liquidate_gigahdx` use this same address.

**For the second pool approach**, the following runtime changes are needed:

1. **`AaveMoneyMarket`** (`runtime/hydradx/src/gigahdx.rs`):
   - Must call supply/withdraw on the GIGAHDX Pool (`Pool-Proxy-GIGAHDX`), not the Hydration Pool
   - Either add a second storage value `GigaHdxBorrowingContract` or make `AaveMoneyMarket` use a constant for the GIGAHDX pool address

2. **`pallet-liquidation`** (`pallets/liquidation/src/lib.rs`):
   - `liquidate_gigahdx()` must call `borrow` and `liquidationCall` on the GIGAHDX pool, not the main pool
   - Add `GigaHdxPool` config type or storage value
   - Currently hardcodes `sthdx_asset_id: AssetId = 670` — this is fine

3. **`BorrowingContract`** stays as-is for regular liquidations (DOT, ETH, etc.)

4. **No changes needed to:**
   - `pallet-gigahdx` (doesn't reference pool directly, uses `MoneyMarketOperations` trait)
   - `pallet-gigahdx-voting` (only manages locks)
   - `pallet-fee-processor` (only manages fee distribution)
   - LockableAToken / 0x0806 precompile (pool-agnostic)

### Runtime parameter values

From `runtime/hydradx/src/gigahdx.rs`:
```
StHdxAssetId = 670
GigaHdxAssetId = 67
GigaHdxPalletId = *b"gigahdx!"
GigaHdxCooldownPeriod = 222 * DAYS
GigaHdxMinStake = 10 HDX
GigaHdxMaxUnstakePositions = 10
GigaHdxMaxVotes = 25
```

---

## Deployment Sequence

### Phase 0: Runtime upgrade (HydraDX-node)

Build and deploy runtime with:
- `pallet-gigahdx`
- `pallet-gigahdx-voting`
- `pallet-fee-processor`
- `pallet-liquidation` updates (GIGAHDX liquidation + second pool support)
- LockManager precompile at 0x0806

**Must happen before Phase 2** (pool deploy needs runtime EVM support).

### Phase 1: Deploy stHDX USDOracleAdapter (already done?)

Oracle address: `0x202df3eDac2775b857ee2f61A3569731E53eC713`

### Phase 2: Deploy GIGAHDX Pool (aave-v3-deploy)

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy --tags market```

Deploys:
- `PoolAddressesProvider-GIGAHDX` (ProviderId 222223)
- `Pool-Proxy-GIGAHDX`
- `PoolConfigurator-Proxy-GIGAHDX`
- `ACLManager-GIGAHDX`
- `AaveOracle-GIGAHDX`
- `PoolDataProvider-GIGAHDX`
- Token implementations (`AToken-GIGAHDX`, `StableDebtToken-GIGAHDX`, `VariableDebtToken-GIGAHDX`)

### Phase 3: Deploy LockableAToken (aave-v3-deploy)

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy-LockableAToken```

Creates `LockableAToken-GIGAHDX` artifact.

### Phase 4: Deploy GHO implementations for GIGAHDX (gho-core)

Deploy GhoAToken, GhoStableDebtToken, GhoVariableDebtToken, GhoInterestRateStrategy
referencing the GIGAHDX pool address.

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy --tags gigahdx_gho_deploy```

Creates: `GhoAToken-GIGAHDX`, `GhoStableDebtToken-GIGAHDX`, `GhoVariableDebtToken-GIGAHDX`, `GhoInterestRateStrategy-GIGAHDX` (4.5% APY)

Then copy artifacts to aave-v3-deploy:
```bash
cp ../gho-core/deployments/hydration/GhoAToken-GIGAHDX.json deployments/hydration/
cp ../gho-core/deployments/hydration/GhoStableDebtToken-GIGAHDX.json deployments/hydration/
cp ../gho-core/deployments/hydration/GhoVariableDebtToken-GIGAHDX.json deployments/hydration/
cp ../gho-core/deployments/hydration/GhoInterestRateStrategy-GIGAHDX.json deployments/hydration/
```

### Phase 5: Generate governance proposal (aave-v3-deploy)

```bash
MARKET_NAME=GIGAHDX HARDHAT_NETWORK=hydration FORK=hydration npx hardhat gigahdx-launch```

The proposal does (atomically):

**EVM calls:**
1. Init stHDX reserve (oracle, rate strategy, LockableAToken, risk params)
2. Review reserve factors
3. Init HOLLAR reserve with GhoAToken/GhoVariableDebtToken impls
4. Enable HOLLAR borrowing
5. Set HOLLAR oracle ($1) in GIGAHDX AaveOracle
6. Register GIGAHDX GhoAToken as HOLLAR facilitator (1M bucket)
7. Set GHO cross-references (aToken ↔ variableDebtToken, treasury, ZeroDiscountRateStrategy)

**Substrate calls:**
8. Register stHDX (asset 670) in Hydration asset registry (ED: 3 stHDX)
9. Register GIGAHDX (asset 67) as Erc20 pointing to aToken (ED: 3 GIGAHDX)

### Phase 6: Set GIGAHDX pool address in runtime

After pool is deployed, set the GIGAHDX pool address in:
- `AaveMoneyMarket` adapter (so supply/withdraw targets the right pool)
- `pallet-liquidation` (so GIGAHDX liquidations target the right pool)

This can be a governance extrinsic or part of a subsequent runtime upgrade.

### Phase 7: Submit proposal

Submit the generated preimage to Hydration governance via referendum.

### Phase 8: Post-execution verification

1. `Pool-Proxy-GIGAHDX` registered in PoolAddressesProviderRegistry (id 222223)
2. stHDX reserve active — supply only, LockableAToken, no borrowing
3. HOLLAR reserve active — GhoAToken, borrow only, no collateral value
4. GIGAHDX GhoAToken registered as facilitator on GhoToken (1M bucket)
5. Test: supply stHDX → borrow HOLLAR → repay → withdraw
6. Test: giga_stake HDX → get GIGAHDX → vote → liquidation clears locks
7. Existing Hydration Market pool unaffected

---

## Key Addresses

| Contract | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| HDX/USD oracle | `0xea63e594ee00590938E856F2134E6C792bA92d13` |
| stHDX USDOracleAdapter | `0x202df3eDac2775b857ee2f61A3569731E53eC713` |
| stHDX token | `tokenAddress(670)` |
| Existing Hydration Pool | `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38` |

## Risk Parameters (stHDX)

| Parameter | Value |
|---|---|
| LTV | 40% |
| Liquidation Threshold | 70% |
| Liquidation Bonus | 8% |
| Reserve Factor | 20% |
| Supply Cap | 500,000,000 |
| Borrow Cap | 0 (collateral only) |
| Debt Ceiling | 0 (facilitator bucket limits HOLLAR) |
| Decimals | 12 |
| aToken Impl | LockableAToken |

## HOLLAR Facilitator

| Facilitator | Bucket Capacity |
|---|---|
| Hydration Market (existing) | 7M |
| Flash Minter | 100K |
| HSM | 18M |
| **GIGAHDX (new)** | **1M** |
