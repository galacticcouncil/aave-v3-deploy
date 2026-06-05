# forktest/ — Verity-bytecode differential & fork harness

Exercises the **Verity-emitted bytecode** (not the Lean proofs) against mocks and, eventually, a real
Aave fork — the level-2 "behavioral parity" of `../PARITY.md`. Kept **outside** the Foundry `test/`
path on purpose, so it can't break the green Solidity suite; wire it in per "How to run" once the two
gates below are met.

## Gates (why it isn't runnable yet)

1. **standalone `solc` 0.8.33** (Verity's pin) to lower `../yul/*.yul` → bytecode. Foundry's managed
   solc only covers the `.sol` side. Get it via `svm install 0.8.33` or Verity's `make setup-solc`.
2. **`uint16` selector fix.** Verity models `uint16 referralCode` as `Uint256`, so the emitted `supply`
   (`0xe9c7359c`) / `borrow` (`0xa2b86e7b`) selectors differ from mainnet Aave (`0x617ba037` /
   `0xa415bcad`). Against the real pool (or the stock `MockPool`, which uses the `uint16` selectors)
   those two calls miss. `repay`/`withdraw` + the inter-contract `mint`/`deposit`/`pokeRepay` already
   match. Until fixed, test against `MockAaveU256` here (mirrors the emitted `uint256` selectors), or
   stub the two calls.

## Files

- `build-yul.sh` — `solc --strict-assembly --optimize` over `../yul/*.yul` → `bytecode/<name>.bin`.
- `VerityParity.t.sol` — template Foundry test: deploy the Verity `CollateralVaultAave` bytecode, run
  `deposit` against `MockAaveU256` + mock synth/loop, assert the accounting storage slots and that the
  mocks recorded the calls. Compares the *internal accounting* to the Solidity vault (ABIs differ, so
  it's state-parity, not call-for-call).

## How to run (once gated items are met)

```sh
# 1. build the bytecode
SOLC=$(svm use 0.8.33 >/dev/null; which solc) ./build-yul.sh
# 2. wire the test into the Foundry tree and run it
cp VerityParity.t.sol ../../../test/formal/        # test = "test" in foundry.toml
forge test --match-path 'test/formal/VerityParity.t.sol' -vvv
# 3. (optional) real Aave fork — needs the uint16 fix first
RPC_HYDRATION=<url> forge test --match-path 'test/formal/VerityParity.t.sol' --fork-url hydration
```

## What it proves vs. what it doesn't

- **Proves:** the Verity bytecode dispatches and issues the cross-contract calls with correctly
  ABI-encoded args, and its accounting storage evolves identically to the model (and, where ABIs
  overlap, to the Solidity vault's core accounting).
- **Doesn't:** ABI/selector drop-in equivalence (the Verity vault is a reference model — see
  `../PARITY.md` §3). The strong parity guarantee is the shared-invariant matrix (`../PARITY.md` §1),
  which is already green on both sides.
