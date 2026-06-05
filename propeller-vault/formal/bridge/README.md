# bridge/ — Verity-native Propeller contracts (Lean → EVM)

Phase 4 of the formal-verification plan: Propeller contracts written in the **Verity** EDSL
(Lean 4 → IR → Yul → EVM, with a proven compiler) — *implementation, spec, proof, and bytecode
from one Lean source*. This is the EVM bridge the ℝ-spec in `../` targets.

This dir holds the **artifacts** (contract source, machine-checked proofs, generated Yul). It is
not built by the sibling `formal/` Lake project (that pins Lean v4.30.0; Verity pins v4.22.0) —
build it against a Verity checkout, as below.

## Contents

```
SyntheticToken/{Contract,Spec,Proofs}.lean    the synthetic ERC20 (mint/burn onlyVault)
CollateralVault/{Contract,Spec,Proofs}.lean   ERC4626 vault: deposit · requestRedeem · claim
yul/SyntheticToken.yul                         compiler output (object + runtime + selector dispatch)
yul/CollateralVault.yul                        compiler output
contracts.manifest                             compiler manifest (both contracts)
```

## What's proven (all axiom-clean: `propext`/`Classical.choice`/`Quot.sound`, 0 `sorry`)

**SyntheticToken**
- `mint_meets_spec_when_vault` / `burn_meets_spec_when_vault` — under the `onlyVault` guard, mint/burn
  exactly realize their storage transition (balance + total-supply update, all else framed unchanged).
- `mint_increases_supply` / `burn_decreases_supply` — supply moves by exactly `amount` (the on-chain
  basis for the synthetic tracking the Main HOLLAR debt → `principalFloored` in `../PropellerLean/`).

**CollateralVault** — the headline is the share-conservation invariant
`assets_supply_synced` (`totalAssets == totalSupply`, 1:1), proven **preserved by every op**:
- `deposit_preserves_synced` — deposit raises both by `assets`.
- `requestRedeem_preserves_synced` — escrowing shares (balance→escrow) touches neither slot.
- `claim_preserves_synced` — claim lowers both by `shares`.
- read-only `balanceOf` / `escrowOf` / `totalAssets` / `totalSupply` meet their specs.

The generated Yul carries the guards faithfully (e.g. `"SYNTH: only vault"` revert, checked
overflow, `lt(balance, amount)` underflow guards) and a `switch shr(224, calldataload(0))` dispatch.

## Scope of this cut

These model the **token + share-accounting cores**. The Aave legs — `supply` collateral,
`borrow` HOLLAR, and the `SyntheticToken.mint`/`burn` cross-calls from the vault — are **external
calls realized as ECMs** (typed interfaces), sound *by assumption* on Aave's spec. That is the
documented trust boundary and the next step; see `../BRIDGE_SPIKE.md`.

## Reproduce

```sh
# 1. Verity (pins Lean v4.22.0, Mathlib, EVMYulLean) — pinned here: verity 23e46d2 / EVMYulLean 7785a9b
git clone https://github.com/lfglabs-dev/verity && cd verity
lake exe cache get
# 2. drop the contracts in and register them
cp -r /path/to/bridge/SyntheticToken  Contracts/SyntheticToken
cp -r /path/to/bridge/CollateralVault Contracts/CollateralVault
#    add `.andSubmodules `Contracts.SyntheticToken,` and `.andSubmodules `Contracts.CollateralVault,`
#    to the Contracts lib glob in lakefile.lean, and create the aggregator modules:
printf 'import Contracts.SyntheticToken.Contract\nimport Contracts.SyntheticToken.Spec\n' > Contracts/SyntheticToken.lean
printf 'import Contracts.CollateralVault.Contract\nimport Contracts.CollateralVault.Spec\n'   > Contracts/CollateralVault.lean
# 3. build + verify proofs
lake build Contracts.SyntheticToken Contracts.SyntheticToken.Proofs \
           Contracts.CollateralVault Contracts.CollateralVault.Proofs
# 4. compile to Yul
lake build verity-compiler
cp /path/to/bridge/contracts.manifest .
./.lake/build/bin/verity-compiler --manifest contracts.manifest --output yul
# 5. (optional) Yul → bytecode — the one unverified step
make setup-solc && solc --strict-assembly --bin yul/CollateralVault.yul
```

## Trust boundary (see BRIDGE_SPIKE.md)

- `Yul → bytecode` delegated to `solc` (0.8.33, Cancun) — not verified by Verity; runs on Osaka (superset).
- Aave / cross-contract calls — typed-interface ECMs, sound by assumption; scope with
  `--deny-low-level-mechanics` + `--trust-report`.

## Next contracts

`SubLoop` (single-step `pokeBorrow`/`pokeRepay`, PRIME isolation loop) → `Harvester` (keeper guards)
→ the Aave typed-interface ECMs (`IPool.supply/borrow/repay/withdraw`) wiring the legs together.
