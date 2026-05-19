# Library Split Plan — Get HDCLVault Under EIP-170 / Deployable on Hydration

> Branch: `feat/hdcl-vault` @ `9ff358f`
> Date: 2026-05-19
> Companion docs: `DEPLOYMENT.md`, `x-ray/x-ray.md`

---

## Problem statement (numbers)

| Metric | Current | Limit | Excess |
|---|---|---|---|
| `HDCLVault` deployed bytecode | **26,968** | **24,576** (EIP-170) | +2,392 B |
| `HDCLVault` impl deploy tx gas | **17,932,114** | **15,000,000** (Hydration mainnet block limit) | +2,932,114 |

Both ceilings are external — not enforced by forge, but by the EVM (EIP-170) and the chain (per-block gas cap). The contract **cannot deploy to Hydration mainnet** as it stands; nothing about the deploy machinery can work around this.

Root cause: the W0/W1/W2 work added ~600 lines of ERC-4626 + ERC-7540 + multi-pool surface to what was a ~1100-line contract. We're now at 1701 lines and over the EVM's deployable size.

---

## Strategy: phased, measured, stop-after-each

Three phases. After each, **rebuild, re-measure bytecode, re-estimate deploy gas, run the full test suite (344 tests)**. Stop the moment both ceilings are cleared with a comfortable buffer. Don't pre-commit to phases that aren't needed.

### Target buffer

Aim for **~22,500 B bytecode** (2 KB under EIP-170) and **~13M gas** (2M under the 15M block cap). This leaves headroom for the small surface tweaks the audit pass will inevitably require.

---

## Phase 1 — Custom errors pass &nbsp; [LOW RISK · MECHANICAL]

**Estimated savings: 600 B – 1.5 KB**

The contract has 22 `require(cond, "string")` calls. Each string literal costs ~32 B of bytecode plus revert-encoding overhead. Custom errors compile to a 4-byte selector — typically 50–80 B savings per converted call.

### Steps

1. Inventory the 22 require-strings (grep + scan).
2. For each, define a custom error in the `ERRORS` section (line 314):
   ```solidity
   error ZeroReceiver();
   error ZeroController();
   error InsufficientClaimable();
   error NotAuthorized();
   // ... etc
   ```
3. Replace `require(cond, "msg")` → `if (!cond) revert FooError();`.
4. Update any test that matched on `vm.expectRevert("string")` to `vm.expectRevert(HDCLVault.FooError.selector)`.

### Risk

Mechanical. Custom errors are an audit-positive change (better gas, structured revert data). The only risk is tests that asserted on revert *strings* — those need their selectors updated.

### Stop criterion

After this, rebuild and check: if bytecode ≤ 22,500 B AND deploy gas ≤ 13M → **STOP. Done.**

### Effort: ~30 min mechanical + test fixup.

---

## Phase 2 — Extract `QueueLib` &nbsp; [MEDIUM RISK · STRUCTURAL]

**Estimated savings: 2 – 4 KB additional**

Three dense functions are pure queue mechanics with self-contained logic:

| Function | Lines | Approx. bytecode contribution |
|---|---|---|
| `_processQueueWithHollar` (1517–1619) | 103 | ~2 – 3 KB |
| `_claimByShares` (683–711) | 29 | ~600 – 900 B |
| `_claimByAssets` (716–744) | 29 | ~600 – 900 B |

All three operate on the same state: `redemptionQueue` mapping, `queueHead`, `queueTail`, `totalQueuedHdcl`, `totalReservedHollar`, `idleHollar`. None of them touch position state, role checks, or pool state. **Clean extraction boundary.**

### Library shape

```solidity
// src/libraries/QueueLib.sol
library QueueLib {
    struct Request {
        address user;
        uint256 hdclAmount;
        uint256 hdclSettled;
        uint256 hollarOwed;
    }

    error InsufficientClaimable();

    event RedemptionFulfilled(uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 hdclBurned);
    event RedemptionPartiallyFulfilled(uint256 indexed requestId, address indexed user, uint256 hollarAmount, uint256 hdclBurned);

    /// Pass storage refs explicitly; everything else by value. Library
    /// returns the deltas the caller needs to apply to its own globals
    /// (idleHollar, totalReservedHollar). Caller is responsible for the
    /// outer `idleHollar -= used` / `totalReservedHollar += used` updates
    /// to keep storage writes co-located in the calling contract.
    function processQueue(
        mapping(uint256 => Request) storage queue,
        uint256 queueHead_,
        uint256 queueTail_,
        uint256 available,
        uint256 rate,
        uint256 maxIterations,
        uint256 maxSkips
    ) public returns (
        uint256 newQueueHead,
        uint256 hollarUsed,
        uint256 hdclLocked
    );

    function claimByShares(
        mapping(uint256 => Request) storage queue,
        uint256 queueTail_,
        address controller,
        uint256 shares
    ) public returns (uint256 assets);

    function claimByAssets(
        mapping(uint256 => Request) storage queue,
        uint256 queueTail_,
        address controller,
        uint256 assets
    ) public returns (uint256 shares, uint256 actualAssets);
}
```

### Key design rules

1. **`public` library functions** — only `public`/`external` library functions get DELEGATECALLed and live in a separate deployed contract. `internal` library functions are *inlined* into the caller (zero bytecode savings). All three functions above MUST be `public`.

2. **Storage refs by argument** — Solidity lets `public` library functions take `mapping(...) storage` refs across the library boundary. The DELEGATECALL preserves storage context.

3. **Events live in the library** — Discord-tested pattern: events declared in the library, emitted by library functions, decoded normally by indexers (events are tied to the emitting *address*, which under DELEGATECALL is still the vault proxy).

4. **Single struct definition** — move `RedemptionRequest` → `QueueLib.Request`. The vault imports it via `using QueueLib for ...` or references the qualified name.

5. **Vault keeps the storage variables** — `redemptionQueue`, `queueHead`, `queueTail`, etc. **stay as `HDCLVault` storage slots, unchanged.** Storage layout is preserved for UUPS upgrade safety.

### Call-site changes in `HDCLVault.sol`

```solidity
// Before: internal call
function _processQueueWithHollar(uint256 available, uint256 rate)
    internal returns (uint256 hollarUsed, uint256 hdclLocked) { /* 100 lines */ }

// After: thin dispatcher
function _processQueueWithHollar(uint256 available, uint256 rate)
    internal returns (uint256 hollarUsed, uint256 hdclLocked)
{
    uint256 newHead;
    (newHead, hollarUsed, hdclLocked) = QueueLib.processQueue(
        redemptionQueue,
        queueHead,
        queueTail,
        available,
        rate,
        MAX_QUEUE_ITERATIONS,
        MAX_QUEUE_SKIPS
    );
    queueHead = newHead;
}
```

### Upgrade implications

- The library deploys ONCE as a separate contract. Its address gets **link-time hardcoded** into the vault impl bytecode.
- To upgrade *library* logic: deploy new library, redeploy vault impl pointing at new library address, `upgradeToAndCall(newVaultImpl)`. Same number of steps as a vault-only upgrade, just two deploys instead of one.
- **No storage migration risk** — the vault's slot layout is identical before/after.

### Risk areas (audit attention)

1. **Pro-rata math in claim functions** — `(take * r.hollarOwed) / r.hdclSettled` and friends. Moving across library boundary doesn't change semantics, but every test that exercises partial settles + multi-claim must pass.
2. **`MAX_QUEUE_ITERATIONS` and `MAX_QUEUE_SKIPS`** — passed as args. The vault keeps the constants; library is parameterized for testability.
3. **Cursor invariants in `processQueue`** — the `cursor == queueHead` co-located advance pattern, the partial-settle break, and the catastrophic-rate guard (`hollarValue == 0` break) all need to land verbatim.
4. **`InsufficientClaimable` revert** — was a string `require`. After Phase 1 it'll already be a custom error; just move the error declaration into the library.

### Test surface

The full 344-test suite should pass unchanged. Key spots to watch:
- `test/unit/PullRedemption.t.sol` (10 tests) — direct queue mechanics
- `test/unit/PartialRedeemRounding.t.sol` — pro-rata correctness
- `test/unit/QueueGrief.t.sol` — cursor / skip iteration bounds
- `test/unit/RedemptionQueue.t.sol` — FIFO semantics
- `test/invariant/InvariantVault.t.sol` — INV-10/11/13 (totalReservedHollar accuracy, per-request consistency)

### Stop criterion

After this, rebuild + run tests + check bytecode/gas. If both ceilings cleared with buffer → **STOP. Ship.**

### Effort: ~4 – 6 hours including test runs and a careful diff review.

---

## Phase 3 — Extract `ViewLib` &nbsp; [LOW RISK · IF NEEDED]

**Estimated savings: 1 – 2 KB additional**

Only execute if Phase 2 didn't get us under target. Move pure / view-only functions to a library:

| Candidate | Lines | Notes |
|---|---|---|
| `getEstimatedWaitTime` | 1141–1187 | Two loops over queue + positions. Pure view over storage. |
| `pendingRedeemRequest` | 1117–1125 | Tiny, but each adds dispatcher overhead. |
| `claimableRedeemRequest` | 1129–1137 | Same. |
| ERC-4626 math (`convertToShares`, `convertToAssets`, `previewMint`, `previewDeposit`, `previewRedeem`) | 1014–1103 | Pure math given supply/totalAssets. |

These can sometimes be expressed as `internal` library functions that take all needed values as args — at which point they inline back into the vault (zero saving). To get savings, they must be `public` library functions.

For ERC-4626 math: pure functions taking `(uint256 totalSupply, uint256 totalAssets, uint256 amount)` would be `pure`, so they could legitimately be `public pure` functions in a library deployed once. Each call becomes a DELEGATECALL though, so gas cost goes up modestly.

### Risk

Low — these are read-only. Test surface narrow (the existing ERC4626.t.sol and ERC7540Views.t.sol tests).

### Stop criterion

Bytecode ≤ 22,500 B → ship.

### Effort: ~2 – 3 hours.

---

## What NOT to extract

- **`pokeDecentral`** (state machine) — too much state coupling. The library would need refs to 8+ storage variables, multiple events, and per-pool interface calls. Diminishing returns vs. audit-risk increase.
- **`deposit` / `mint` / `requestRedeem` / `redeem` / `withdraw`** — these are the entry points; users interact with them directly. Moving them to a library means every call becomes a DELEGATECALL of a DELEGATECALL (entry → vault impl → library impl) — fine functionally, but obscures the audit story.
- **Admin functions** (`registerPool`, `setActiveDepositPool`, `setTvlCap`, etc.) — small, role-gated, and rare to call. Not bytecode-dense enough to justify extraction.
- **`_addToBucket`, `_removeYieldFromBucket`, `_removePrincipalFromBucket`** — small one-liners. `internal` library would inline (no save); `public` library would DELEGATECALL for ~30 bytes of logic (loss).

---

## Sequencing checklist

```
[ ] Phase 1: custom errors pass
    [ ] Inventory 22 require-strings
    [ ] Define matching custom errors in ERRORS section
    [ ] Replace require() → if/revert
    [ ] Fix test expectations (vm.expectRevert)
    [ ] forge build && check bytecode size
    [ ] forge test (344 tests pass)
    [ ] If bytecode ≤ 22,500 B + gas ≤ 13M → STOP, commit, deploy attempt
    [ ] Otherwise → continue to Phase 2

[ ] Phase 2: QueueLib
    [ ] Create src/libraries/QueueLib.sol with Request struct + 3 public functions
    [ ] Move event declarations into library
    [ ] Update HDCLVault.sol to use QueueLib (storage refs unchanged)
    [ ] Add library deploy step to Deploy.s.sol (deploy QueueLib first, link into vault impl)
    [ ] forge build && check bytecode
    [ ] forge test (344 tests pass)
    [ ] Update DEPLOYMENT.md step 1 (note the extra library deploy)
    [ ] If both ceilings cleared with buffer → STOP, commit, deploy attempt
    [ ] Otherwise → continue to Phase 3

[ ] Phase 3: ViewLib (only if needed)
    [ ] Create src/libraries/ViewLib.sol with pure math + view functions
    [ ] Migrate the call sites
    [ ] forge build + test + measure
    [ ] Ship.
```

---

## Verification at each phase

```sh
cd hdcl-vault

# Build with same flags as production
forge build

# Measure deployed bytecode
jq -r '.deployedBytecode.object | length / 2' out/HDCLVault.sol/HDCLVault.json
# Target: ≤ 22,500 B

# Estimate impl deploy gas via dry-run script (or just check forge's broadcast log
# from a prior attempt)

# Full test suite
forge test
# Target: 344/344 pass

# Coverage didn't regress
forge coverage --no-match-coverage "(test|script|mocks)" --report summary
# Target: ≥ 99% lines, 100% functions
```

---

## Why not just split the contract into multiple impls?

We considered: **diamond pattern**, **proxy-of-proxies**, **separate Viewer contract holding the proxy**. All work, but:

- **Diamond** — large refactor, changes the public ABI shape, audit-heavy
- **Proxy-of-proxies** — confusing for integrators, multiple upgrade authorities
- **Separate Viewer** — moves read-only functions to a different address, breaking the "single canonical vault address" mental model (and many integrations like Aave's price-feed wire)

Library extraction keeps the vault address singular, the public ABI identical, and storage layout unchanged. It's the lowest-impact path that solves the actual problem.
