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
SubLoop/{Contract,Spec,Proofs}.lean           PRIME-isolation loop: deposit · pokeBorrow · pokeRepay · requestUnwind
Harvester/{Contract,Spec,Proofs}.lean         keeper: maintainPeg · deLever (guarded)
yul/{SyntheticToken,CollateralVault,SubLoop,Harvester}.yul   compiler output (object + runtime + dispatch)
contracts.manifest                             compiler manifest (all four contracts)
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

**SubLoop** — the PRIME-isolation loop; gradual DCA means one keeper step per tx (no in-contract
loop). Headline is **equity-neutrality** of the keeper steps:
- `pokeBorrow_equity_neutral` — `pokeBorrow` raises `primeAmt` and `subDebt` by the *same* `amount`.
- `pokeRepay_equity_neutral` — `pokeRepay` lowers both by the *same* `amount`.
- so loop equity (`primeAmt − subDebt`) is invariant under both: leverage moves, equity doesn't —
  which is exactly why the loop's risk is rate-spread (carry), not price-gap (§3 of the spec).
- read-only `primeAmt` / `subDebt` / `balanceOf` meet their specs.

**Harvester** — the keeper; each entrypoint re-checks an on-chain guard (mirrors HSM/liquidation):
- `maintainPeg_restores_floor` — after `maintainPeg`, `synthValue ≥ mainDebt` (the on-chain
  re-establishment of `principalFloored`, mirroring ℝ `maintainPeg_floors`).
- `deLever_reverts_when_healthy` — `deLever` **reverts** when the guard fails (loop above the
  trigger): a healthy loop can never be force-de-levered. *(Guard enforcement — a revert-path proof.)*
- `deLever_succeeds_when_unhealthy` — when at/under the trigger, `deLever` fires and restores health.

The generated Yul carries the guards faithfully (e.g. `"SYNTH: only vault"` / `"HARV: loop healthy…"`
reverts, checked overflow, `lt(balance, amount)` underflow guards) and a `switch shr(224, calldataload(0))` dispatch.

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

## Aave wiring (`CollateralVaultAave/`)

`deposit` mints shares 1:1 + records the HOLLAR debt (effects), then **supplies the collateral to
Aave and borrows HOLLAR against it** (interactions) — Solidity runtime step 2 ("supply ETH, then
borrow HOLLAR ≤74% LTV"). Both are typed-interface ECMs:
`interface IPool where function supply(…); function borrow(…) end`, invoked as
`pool.supply …` / `pool.borrow …`. `deposit` is annotated `allow_post_interaction_writes` (see §3b of
`AAVE_ECM_DIAGNOSIS.md`): all storage writes precede both calls, and the only thing after the first
call is the second call to the same trusted pool.

**Machine-checked wiring (`Wiring.lean`, `decide`, no axioms):**
- `externals_are_supply_then_borrow` — external set is exactly `["IPool.supply", "IPool.borrow"]`.
- `deposit_issues_supply_call` / `deposit_issues_borrow_call` — `deposit` issues each as a
  state-writing `externalCallWithReturn` ECM (supply: 5 args; borrow: 6 args).
- `deposit_issues_exactly_two_calls` — and no others.

Same verification standard Verity uses for its own typed-interface contracts. The emitted
`yul/CollateralVaultAave.yul` contains both `call(gas(), pool, …)` instructions, effects-first.

**Honest status / caveats:**
- Real Aave `supply` is `void`; Verity interface methods require a return type, so it's declared
  `returns (Bool)` and the value ignored (`_ok`) — a one-line change when a void external-call ECM
  lands; the emitted `call` is identical.
- **Yul emission for ECM specs** hits a native-eval limitation in this Verity build (`evalConstCheck`
  on the ECM `compile` closure) — the spec evaluates fine in-interpreter (`#eval`), so this is
  compiler plumbing, not a modelling gap. Emission is gated on Verity's ECM/linking flow.
- The external call is `writesState` (conservative), so the clean axiom-clean `assets == supply`
  accounting proof of the pure `CollateralVault/` no longer holds *unconditionally* on the wired
  variant — it now sits on the **external-call trust assumption** (Aave `supply` doesn't reenter or
  mutate this contract's slots). That is exactly the documented boundary; the pure `CollateralVault/`
  retains the unconditional proof.

## Next

Remaining Aave surface as ECMs (sound by assumption): `IPool.borrow/repay/withdraw`, plus the other
cross-calls (`CollateralVault → SyntheticToken.mint`, `→ SubLoop.deposit`, `Harvester → SubLoop.pokeRepay`).
Compile each with `--deny-low-level-mechanics` + `--trust-report`.
