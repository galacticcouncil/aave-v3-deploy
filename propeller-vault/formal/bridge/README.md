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
- `deLeverLoop` adds the **inter-contract** call `SubLoop.pokeRepay` (`Wiring.lean`,
  `external_is_subloop_pokeRepay` / `deLeverLoop_issues_pokeRepay`, `decide`/no axioms); and
  `deLeverLoop_reverts_when_healthy` proves the guard **still protects** the wired path — a healthy
  loop can't be de-levered even though `deLeverLoop` makes a cross-contract call.

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

`CollateralVaultAave` wires the full deposit flow + unwind across three contracts — Aave's pool
(`IPool`), our `SyntheticToken` (`ISynth`), and our `SubLoop` (`ISubLoop`):

- **`deposit`** (Solidity steps 2–4): mint shares + record debt & synthetic (effects) → `pool.supply`
  collateral → `pool.borrow` HOLLAR → **`synth.mint`** the synthetic → **`loop.deposit`** seeds the
  SubLoop (interactions). The last two are the **inter-contract** calls.
- **`pokeSettle`** (Solidity step 5, unwind): lower debt + shares + assets (effects) → `pool.repay`
  the HOLLAR debt, then `pool.withdraw` the freed collateral (interactions).

Both are multi-call functions annotated `allow_post_interaction_writes` (see §3b of
`AAVE_ECM_DIAGNOSIS.md`): all storage writes precede every call, and the only thing after the first
call is the second call to the same trusted pool.

**Machine-checked wiring (`Wiring.lean`, `decide`, no axioms):**
- `externals_are_the_six_calls` — external set is exactly the four Aave calls plus
  `ISynth.mint`, `ISubLoop.deposit`.
- `deposit_issues_supply_call` / `…_borrow_call` / `…_synth_mint` / `…_subloop_deposit` /
  `deposit_issues_exactly_four_calls`.
- `pokeSettle_issues_repay_call` / `…_withdraw_call` / `…_exactly_two_calls`.

Same verification standard Verity uses for its own typed-interface contracts. The emitted
`yul/CollateralVaultAave.yul` contains all six `call(gas(), …)` instructions, effects-first.

**Selector fidelity:**
- Aave `repay` (`0x573ade81`) and `withdraw` (`0x69328dec`) **match mainnet exactly** (no `uint16`);
  `supply`/`borrow` differ (`0xe9c7359c`/`0xa2b86e7b` vs `0x617ba037`/`0xa415bcad`) only from the
  `uint16 referralCode → Uint256` model.
- The **inter-contract** selectors are self-consistent: `mint` → `0x40c10f19` (= `mint(address,uint256)`,
  our `SyntheticToken.mint`) and `deposit` → `0xb6b55f25` (= `deposit(uint256)`, our `SubLoop.deposit`),
  so the vault dispatches to exactly the right entrypoints on our own contracts.

**Honest status / caveats:**
- Real Aave `supply`/`borrow` are `void`; Verity interface methods require a return type, so each is
  declared `returns (Bool)` and the value ignored — a one-line change when a void external-call ECM
  lands; the emitted `call` is identical.
- **Yul emission now works through the stock `verity-compiler` CLI** — the two compiler bugs that
  blocked it ([verity#1951](https://github.com/lfglabs-dev/verity/issues/1951) `loadExts`/`supportInterpreter`,
  [verity#1952](https://github.com/lfglabs-dev/verity/issues/1952) dotted external name) are fixed in
  the Verity checkout. The committed `yul/CollateralVaultAave.yul` is stock-CLI output; the earlier
  static-reference workaround is obsolete. (Those fixes are upstream-Verity source, to be PR'd.)
- The external calls are `writesState`, so the clean axiom-clean `assets == supply` accounting proof
  of the pure `CollateralVault/` no longer holds *unconditionally* on the wired variant — it sits on
  the **external-call trust assumption** (Aave doesn't reenter or mutate this contract's slots). The
  pure `CollateralVault/` retains the unconditional proof.

## Deploy-side wiring

- **Registry:** `CollateralVaultAave`'s constructor stores the `keeper` + canonical dependency
  addresses (`pool`/`synth`/`loop`), exposed via getters. (Interface *call targets* stay params —
  Verity tags interface-ness on params only, so a storage-loaded address can't be a dot-call
  receiver; the registry is the deploy-time config + on-chain reference.)
- **Access control:** `pokeSettle` is `onlyKeeper` — `pokeSettle_reverts_when_not_keeper`
  (`Proofs.lean`) proves a non-keeper caller reverts before any effect or external call, so only the
  registered keeper can drive the unwind/Aave repay+withdraw.
- **SubLoop pokes are `onlyController`:** the constructor stores the controller (keeper/harvester);
  `pokeBorrow`/`pokeRepay` revert for anyone else (`pokeBorrow_reverts_when_not_controller` /
  `pokeRepay_reverts_when_not_controller`). The equity-neutrality theorems are now stated on the
  authorized path (`s.sender = controller`), so leverage can only move via an authorized poke and
  even then keeps loop equity invariant.

## Status

The full Main-position + inter-contract surface is wired and compiles to real `call`-bearing Yul via
the stock CLI:
- **Aave (4):** `supply` · `borrow` (deposit) · `repay` · `withdraw` (unwind) — `CollateralVaultAave`.
- **Inter-contract (3):** `CollateralVault → SyntheticToken.mint` · `→ SubLoop.deposit` (deposit) ·
  `Harvester → SubLoop.pokeRepay` (`deLeverLoop`).

All wiring is `decide`-checked (no axioms); guard enforcement is preserved through the wired paths.

## Next

Compile the whole set with `--deny-low-level-mechanics` + `--trust-report` to archive the trust
surface; address the upstream selector/`uint16` and void-return points (verity PRs #1953/#1954 land
the compile path). Then: deploy-side wiring (constructor addresses, access control on the keeper pokes)
and fork-testing the emitted Yul against a real Aave deployment.
