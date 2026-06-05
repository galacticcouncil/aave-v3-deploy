# bridge/ — Verity-native SyntheticToken (Lean → EVM)

Phase 4 of the formal-verification plan: the first Propeller contract written in the
**Verity** EDSL (Lean 4 → IR → Yul → EVM, with a proven compiler) — *implementation, spec,
proof, and bytecode from one Lean source*. This is the EVM bridge the ℝ-spec in `../` targets.

This dir holds the **artifacts** (contract source, machine-checked proofs, generated Yul). It is
not built by the sibling `formal/` Lake project (that pins Lean v4.30.0; Verity pins v4.22.0) —
build it against a Verity checkout, as below.

## Contents

```
SyntheticToken/Contract.lean   the `verity_contract SyntheticToken` (mint/burn onlyVault, balanceOf, totalSupply)
SyntheticToken/Spec.lean       mint_spec / burn_spec (transition relations) + read-only specs
SyntheticToken/Proofs.lean     machine-checked: mint/burn meet their specs; supply moves by exactly `amount`
yul/SyntheticToken.yul         compiler output — the EVM artifact (object + runtime + selector dispatch)
synth.manifest                 compiler manifest (entry: Contracts.SyntheticToken)
```

## What's proven (all axiom-clean: `propext`/`Classical.choice`/`Quot.sound`, 0 `sorry`)

- `mint_meets_spec_when_vault` / `burn_meets_spec_when_vault` — under the `onlyVault` guard, the
  functions exactly realize the storage transition (balance + total-supply update, all other
  storage framed unchanged).
- `mint_increases_supply_when_vault` / `burn_decreases_supply_when_vault` — total supply moves by
  exactly `amount`. This is the on-chain basis for the synthetic tracking the Main HOLLAR debt
  (`principalFloored` / the peg in `../PropellerLean/Spec/`).
- read-only `balanceOf` / `totalSupply` / `vault` meet their specs.

The generated `yul/SyntheticToken.yul` carries the guards faithfully — e.g. mint reverts with
`"SYNTH: only vault"` (`0x53594e54483a206f6e6c79207661756c74`) when `caller() != sload(0)`, plus
checked-overflow on mint and `lt(balance, amount)` underflow guard on burn — and a
`switch shr(224, calldataload(0))` selector dispatch.

## Reproduce

```sh
# 1. Verity (pins Lean v4.22.0, Mathlib, EVMYulLean)
git clone https://github.com/lfglabs-dev/verity && cd verity
#    pinned during this work: verity 23e46d2 · EVMYulLean 7785a9b
lake exe cache get                 # Mathlib oleans
# 2. drop the contract in and register it
cp -r /path/to/bridge/SyntheticToken Contracts/SyntheticToken
#    add `.andSubmodules `Contracts.SyntheticToken,` to the Contracts lib glob in lakefile.lean
echo 'import Contracts.SyntheticToken.Contract
import Contracts.SyntheticToken.Spec' > Contracts/SyntheticToken.lean
# 3. build + verify proofs
lake build Contracts.SyntheticToken Contracts.SyntheticToken.Proofs
# 4. compile to Yul
lake build verity-compiler
cp /path/to/bridge/synth.manifest .
./.lake/build/bin/verity-compiler --manifest synth.manifest --output yul
# 5. (optional) Yul → bytecode — the one unverified step
make setup-solc                    # pins solc 0.8.33
solc --strict-assembly --bin yul/SyntheticToken.yul
```

## Trust boundary (unchanged from BRIDGE_SPIKE.md)

- `Yul → bytecode` is delegated to `solc` (0.8.33, Cancun) — **not** verified by Verity. Runs on
  Hydration's Osaka EVM (a superset).
- The Aave interaction surface (`supply/borrow/repay/withdraw`) — not in this contract — will use
  typed-interface ECMs, sound *by assumption* on Aave's spec; scope with `--deny-low-level-mechanics`
  + `--trust-report`.

## Next contracts

`CollateralVault` (fork Verity's verified `Contracts/Vault`) → `SubLoop` (single-step
`pokeBorrow`/`pokeRepay`) → `Harvester` → the Aave ECMs. See `../../README.md` and `../BRIDGE_SPIKE.md`.
