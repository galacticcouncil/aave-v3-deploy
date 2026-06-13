# BIL Deployment Plan

Separate Aave V3 money market instance on Hydration for Brazilian Invoice Loans.
- **BIL** (asset 55, 18 decimals) — only collateral, standard AToken
- **HOLLAR** (asset 222, 18 decimals) — only borrowable, GhoAToken facilitator
- BIL price derived from BILVault.exchangeRate() (BIL/HOLLAR, where HOLLAR ≈ $1)

## Key Differences from GIGAHDX

| | GIGAHDX | BIL |
|---|---|---|
| Collateral | stHDX (12 decimals, LockableAToken) | BIL (18 decimals, standard AToken) |
| LTV | 40% | 70% |
| Liquidation Threshold | 70% | 80% |
| Liquidation Bonus | 8% | 7% |
| Supply Cap | 500M | 3M |
| Borrow APR | 4.5% | 10% |
| Oracle | USDOracleAdapter (stHDX→HDX→USD) | BILOracleAdapter (vault exchangeRate) |
| Liquidation | Custom pallet (lock clearing) | Standard Aave |
| aToken receipt asset ID | 67 | 550 |

---

## Deployment Sequence

### Phase 1: Deploy BILOracleAdapter

Deploy the oracle adapter contract that reads `BILVault.exchangeRate()`.

```bash
# Constructor arg: BILVault proxy address
npx hardhat deploy-BILOracleAdapter --vault <BIL_VAULT_ADDRESS> --network hydration
```

The adapter implements `IEACAggregatorProxy` (Chainlink-compatible), returning the exchange rate scaled to 8 decimals. Since HOLLAR ≈ $1, the exchange rate is effectively BIL/USD.

Update `markets/bil/index.ts` ChainlinkAggregator with the deployed address.

### Phase 2: Deploy BIL Pool (aave-v3-deploy)

```bash
MARKET_NAME=BIL HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy --tags market
```

Deploys:
- `PoolAddressesProvider-BIL` (ProviderId 22222255)
- `Pool-Proxy-BIL`
- `PoolConfigurator-Proxy-BIL`
- `ACLManager-BIL`
- `AaveOracle-BIL`
- `PoolDataProvider-BIL`
- Token implementations (`AToken-BIL`, `StableDebtToken-BIL`, `VariableDebtToken-BIL`)

### Phase 3: Deploy HOLLAR token implementations for BIL (hollar repo)

Deploy HOLLAR aToken, stable/variable debt tokens, and interest rate strategy
referencing the BIL pool address.

```bash
MARKET_NAME=BIL HARDHAT_NETWORK=hydration FORK=hydration npx hardhat deploy --tags bil_hollar_deploy
```

Creates: `GhoAToken-BIL`, `GhoStableDebtToken-BIL`, `GhoVariableDebtToken-BIL`, `GhoInterestRateStrategy-BIL` (10% APY)

Then copy artifacts to aave-v3-deploy:
```bash
cp ../hollar/deployments/hydration/GhoAToken-BIL.json deployments/hydration/
cp ../hollar/deployments/hydration/GhoStableDebtToken-BIL.json deployments/hydration/
cp ../hollar/deployments/hydration/GhoVariableDebtToken-BIL.json deployments/hydration/
cp ../hollar/deployments/hydration/GhoInterestRateStrategy-BIL.json deployments/hydration/
```

### Phase 4: Generate governance proposal (aave-v3-deploy)

```bash
MARKET_NAME=BIL HARDHAT_NETWORK=hydration FORK=hydration npx hardhat bil
```

The proposal does (atomically):

**EVM calls:**
1. Init BIL reserve (oracle, rate strategy, standard AToken, risk params)
2. Review reserve factors
3. Init HOLLAR reserve with GhoAToken/GhoVariableDebtToken impls
4. Enable HOLLAR borrowing
5. Set HOLLAR oracle ($1) in BIL AaveOracle
6. Register BIL GhoAToken as HOLLAR facilitator (1M bucket)
7. Set HOLLAR cross-references (aToken ↔ variableDebtToken, treasury, ZeroDiscountRateStrategy)

**Substrate calls:**
8. Register BIL (asset 55) in Hydration asset registry (ED: 0.02 BIL)
9. Register aBIL (asset 550) as Erc20 pointing to aToken (ED: 0.02 aBIL)
10. Enable BIL and aBIL as fee payment currencies

### Phase 5: Submit proposal

Submit the generated preimage to Hydration governance via referendum.

### Phase 6: Post-execution verification

1. `Pool-Proxy-BIL` registered in PoolAddressesProviderRegistry (id 22222255)
2. BIL reserve active — supply only, standard AToken, no borrowing
3. HOLLAR reserve active — GhoAToken, borrow only, no collateral value
4. BIL GhoAToken registered as facilitator on GhoToken (1M bucket)
5. BILOracleAdapter returning correct exchange rate (8 decimals)
6. Test: supply BIL → borrow HOLLAR → repay → withdraw
7. Test: liquidation works via standard `liquidationCall`
8. Existing Hydration Market pool and GIGAHDX pool unaffected

---

## Key Addresses

| Contract | Address |
|---|---|
| HOLLAR (GhoToken) | `0x531a654d1696ED52e7275A8cede955E82620f99a` |
| GhoOracle | `0x6096C9D71F7c06024578a62F4B608a1Bb06834F8` |
| BILVault (2.lark testnet) | `0x4360067b4Ee1C89449bBa7AE6b60940D8562aa35` |
| BIL token | `tokenAddress(55)` |
| Existing Hydration Pool | `0x1b02E051683b5cfaC5929C25E84adb26ECf87B38` |

## Risk Parameters (BIL)

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
| **BIL (new)** | **1M** |

## HOLLAR Borrow Rate

| Parameter | Value |
|---|---|
| Interest Rate Strategy | GhoInterestRateStrategy (fixed) |
| Borrow APR | 10% |
