# forktest/ — Verity-bytecode differential harness

Exercises the **Verity-emitted bytecode** (not the Lean proofs) — the level-2 "behavioral parity" of
`../PARITY.md`. **Runnable and green:** the test deploys the bytecode `solc 0.8.33` produced from
`../yul/CollateralVaultAave.yul`, runs `deposit` against mocks mirroring the emitted selectors, and
asserts every cross-contract call + the accounting storage slots.

## Status

```
forge test --match-path test/formal/VerityParity.t.sol --evm-version shanghai
  [PASS] test_deposit_wires_all_calls   (deploy verity bytecode → deposit → supply/borrow/mint/seed land; slots 0/1/3/4 correct)
  [PASS] test_pokeSettle_onlyKeeper      (non-keeper pokeSettle reverts)
```
Under the default `paris` EVM the test **self-skips** (the bytecode uses `PUSH0`, shanghai+), so the
normal suite stays green. Hydration is Osaka, so shanghai/cancun is the realistic target.

## Files

- `build-yul.sh` — `solc --strict-assembly --optimize` over `../yul/*.yul` → `bytecode/<name>.bin`
  (`0x`-prefixed). Needs `solc 0.8.33` (Verity's pin): `SOLC=/path/to/solc ./build-yul.sh`.
- `bytecode/*.bin` — checked-in artifacts (so the test runs without solc); regenerate with the script.
- the test lives at `../../../test/formal/VerityParity.t.sol` (in the Foundry tree); it reads
  `bytecode/CollateralVaultAave.bin` (needs `fs_permissions` for `./formal`, set in `foundry.toml`).

## Run

```sh
# from propeller-vault/
forge test --match-path 'test/formal/VerityParity.t.sol' --evm-version shanghai -vv
# regenerate bytecode after editing a contract:
SOLC=/path/to/solc-0.8.33 formal/bridge/forktest/build-yul.sh
```

## What it proves vs. doesn't

- **Proves (now, green):** the Verity bytecode dispatches and issues the four cross-contract calls with
  correctly ABI-encoded args (`supply`/`borrow`/`mint`/`subloop.deposit`), evolves its accounting
  storage as the model says, and enforces the `onlyKeeper` guard on `pokeSettle`.
  **All six selectors now match mainnet Aave exactly** (`supply` `0x617ba037`, `borrow` `0xa415bcad`,
  `repay` `0x573ade81`, `withdraw` `0x69328dec`, `mint` `0x40c10f19`, `deposit` `0xb6b55f25`) — the
  `referralCode` params are `Uint16`, so the mock here uses the real Aave ABI and the calldata is
  byte-identical to a live Aave call.
- **Doesn't (the one remaining gap for a *live* fork):** real Aave `supply`/`borrow` are `void`, but
  Verity interface methods require a return type, so they're declared `returns (Bool)` and lower to the
  strict `externalCallWithReturn` ECM, which reverts on `returndatasize() < 32`. Against a void callee
  that reverts after Aave already executed. The mock here `returns (bool)` to satisfy the check. A live
  fork needs a **void / empty-returndata interface call** in Verity (a `bubblingValueCallNoOutput`-style
  ECM routed from a no-return interface method) — analogous to the upstream PRs #1953/#1954.
  `repay`/`withdraw` return `uint256` already, so they're fork-ready as-is.
- ABI drop-in equivalence is **not** a goal — the Verity vault is a reference model (`../PARITY.md` §3).
