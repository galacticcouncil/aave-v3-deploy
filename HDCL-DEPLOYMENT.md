# HDCL Deployment Plan

Separate Aave V3 money market instance on Hydration for Hydrated Decentral.
- **HDCL** (asset 55, 18 decimals) — only collateral, standard AToken
- **HOLLAR** (asset 222, 18 decimals) — only borrowable, GhoAToken facilitator
- HDCL price derived from HDCLVault.exchangeRate() (HDCL/HOLLAR, where HOLLAR ≈ $1)

## Key Differences from GIGAHDX

| | GIGAHDX | HDCL |
|---|---|---|
| Collateral | stHDX (12 decimals, LockableAToken) | HDCL (18 decimals, standard AToken) |
| LTV | 40% | 70% |
| Liquidation Threshold | 70% | 80% |
| Liquidation Bonus | 8% | 7% |
| Supply Cap | 500M | 3M |
| Borrow APR | 4.5% | 10% |
| Oracle | USDOracleAdapter (stHDX→HDX→USD) | HDCLOracleAdapter (vault exchangeRate) |
| Liquidation | Custom pallet (lock clearing) | Standard Aave |
| aToken receipt asset ID | 67 | 550 |

---

## Deployment Sequence

### Phase 1: Deploy HDCLOracleAdapter

Deploy the oracle adapter contract that reads `HDCLVault.exchangeRate()`.

```bash
# Constructor arg: HDCLVault proxy address
npx hardhat deploy-HDCLOracleAdapter --vault <HDCL_VAULT_ADDRESS> --network hydration
```

The adapter implements `IEACAggregatorProxy` (Chainlink-compatible), returning the exchange rate scaled to 8 decimals. Since HOLLAR ≈ $1, the exchange rate is effectively HDCL/USD.

Update `markets/hdcl/index.ts` ChainlinkAggregator with the deployed address.

### Phase 2: Deploy HDCL Pool (aave-v3-deploy)

```bash
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy --tags market
```

Deploys:
- `PoolAddressesProvider-HDCL` (ProviderId 22222255)
- `Pool-Proxy-HDCL`
- `PoolConfigurator-Proxy-HDCL`
- `ACLManager-HDCL`
- `AaveOracle-HDCL`
- `PoolDataProvider-HDCL`
- Token implementations (`AToken-HDCL`, `StableDebtToken-HDCL`, `VariableDebtToken-HDCL`)

### Phase 3: Deploy HOLLAR token implementations for HDCL (hollar repo)

Deploy HOLLAR aToken, stable/variable debt tokens, and interest rate strategy
referencing the HDCL pool address.

```bash
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy --tags hdcl_hollar_deploy
```

Creates: `GhoAToken-HDCL`, `GhoStableDebtToken-HDCL`, `GhoVariableDebtToken-HDCL`, `GhoInterestRateStrategy-HDCL` (10% APY)

Then copy artifacts to aave-v3-deploy:
```bash
cp ../hollar/deployments/hydration/GhoAToken-HDCL.json deployments/hydration/
cp ../hollar/deployments/hydration/GhoStableDebtToken-HDCL.json deployments/hydration/
cp ../hollar/deployments/hydration/GhoVariableDebtToken-HDCL.json deployments/hydration/
cp ../hollar/deployments/hydration/GhoInterestRateStrategy-HDCL.json deployments/hydration/
```

### Phase 4: Generate governance proposal (aave-v3-deploy)

```bash
MARKET_NAME=HDCL HARDHAT_NETWORK=hydration FORK=hydration npx hardhat hdcl
```

The proposal does (atomically):

**EVM calls:**
1. Init HDCL reserve (oracle, rate strategy, standard AToken, risk params)
2. Review reserve factors
3. Init HOLLAR reserve with GhoAToken/GhoVariableDebtToken impls
4. Enable HOLLAR borrowing
5. Set HOLLAR oracle ($1) in HDCL AaveOracle
6. Register HDCL GhoAToken as HOLLAR facilitator (1M bucket)
7. Set HOLLAR cross-references (aToken ↔ variableDebtToken, treasury, ZeroDiscountRateStrategy)

**Substrate calls:**
8. Register HDCL (asset 55) in Hydration asset registry (ED: 0.02 HDCL)
9. Register aHDCL (asset 550) as Erc20 pointing to aToken (ED: 0.02 aHDCL)
10. Enable HDCL and aHDCL as fee payment currencies

### Phase 5: Submit proposal

Submit the generated preimage to Hydration governance via referendum.

### Phase 6: Post-execution verification

1. `Pool-Proxy-HDCL` registered in PoolAddressesProviderRegistry (id 22222255)
2. HDCL reserve active — supply only, standard AToken, no borrowing
3. HOLLAR reserve active — GhoAToken, borrow only, no collateral value
4. HDCL GhoAToken registered as facilitator on GhoToken (1M bucket)
5. HDCLOracleAdapter returning correct exchange rate (8 decimals)
6. Test: supply HDCL → borrow HOLLAR → repay → withdraw
7. Test: liquidation works via standard `liquidationCall`
8. Existing Hydration Market pool and GIGAHDX pool unaffected

---

## Key Addresses

| Contract | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| HDCLVault (2.lark testnet) | `0x4360067b4Ee1C89449bBa7AE6b60940D8562aa35` |
| HDCL token | `tokenAddress(55)` |
| Existing Hydration Pool | `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38` |

## Risk Parameters (HDCL)

| Parameter | Value |
|---|---|
| LTV | 70% |
| Liquidation Threshold | 80% |
| Liquidation Bonus | 7% |
| Liquidation Protocol Fee | 10% |
| Reserve Factor | 20% |
| Supply Cap | 3,000,000 |
| Borrow Cap | 0 (collateral only) |
| Debt Ceiling | 0 (facilitator bucket limits HOLLAR) |
| Decimals | 18 |
| aToken Impl | Standard AToken |

## HOLLAR Facilitator

| Facilitator | Bucket Capacity |
|---|---|
| Hydration Market (existing) | 7M |
| Flash Minter | 100K |
| HSM | 18M |
| GIGAHDX | 1M |
| **HDCL (new)** | **1M** |

## HOLLAR Borrow Rate

| Parameter | Value |
|---|---|
| Interest Rate Strategy | GhoInterestRateStrategy (fixed) |
| Borrow APR | 10% |
