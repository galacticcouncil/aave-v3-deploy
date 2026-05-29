# PRIME oracle — ClampedOracle wrapper

Status: deployed and live on `node.lark.hydration.cloud` (testnet fork). Mainnet swap proposal is pending governance submission.

## Summary

Wrap PRIME's `AaveOracle` source with a `ClampedOracle` so a manipulated or stuck primary feed can't move the reported price more than ±200 bps from the on-chain PRIME/HOLLAR 10-min EMA.

- **Wrapper:** `0x166f286745171D58B6b16E6020f7e48246c816E3`
- **Primary (canonical):** `0x82022F77ae239Ad99bB1F2aC0d8DaFF6Cc976a07` — `PRIMEoracleMRL`, a `ManagedOracle` pushed via Wormhole VAA relayed through Moonbeam.
- **Secondary (sanity bound):** `0x00000102737461626c6573770000008f0000002b` — Hydration's stableswap precompile for the PRIME/HOLLAR pool, 10-min EMA.
- **`maxDiffBps`:** `200` (2%).
- **Decimals:** 8.

## Threat model

The MRL is a multi-hop cross-chain feed. Failure modes on the primary side:

- Wormhole guardian-set compromise (multi-sig of ~13–19 entities — Wormhole has been hit before).
- Moonbeam relayer down or pushing wrong VAA.
- Source-chain oracle compromised on the origin end.
- Wormhole halts → MRL freezes at last pushed value (no staleness check in the wrapper today; see *Open items*).

The pool EMA, by contrast, is on-chain and TWAP-smoothed over 10 minutes — moving it meaningfully requires sustained imbalance, not a flash loan.

We treat the **pool EMA as the manipulation-resistant anchor** and **clamp the MRL into a ±200 bps band around it**. Specifically:

1. Latest MRL inside band → return MRL.
2. Latest MRL outside band → return the band edge (clamped MRL).
3. MRL unavailable → revert (`NoValidPrice`).
4. Pool EMA unavailable → return MRL unclamped (sanity bound dropped, liveness preserved).

Trade-off explicitly accepted: a sustained TWAP manipulation on the pool could drag the reported price by `drift ± maxDiffBps`. Easier to defend against than DoS'ing liquidations during real volatility.

## Why 200 bps

Historical analysis (see *Trend* below) shows the MRL/pool spread has been bounded between **−0.47%** and **+1.25%** over the entire ~100-day MRL lifetime. 200 bps gives ~75 bps of margin over the worst-observed divergence and matches the practical Wormhole update cadence.

Earlier candidate values:

- **100 bps** would already be clamping today (MRL is ~1.25% above pool).
- **300–500 bps** would be safer against future divergence but lets a manipulated MRL move reported price further; given MRL is the riskier side, tighter is the better default.
- **200 bps** sits at the boundary — current behaviour passes MRL through unmodified, but the wrapper will activate the clamp on any further divergence beyond ~75 bps, which is the desired safety property.

## Switch-over impact

Reported PRIME price at the moment of the swap (against `AaveOracle.getAssetPrice`):

| | Address | Price |
|---|---|---|
| Current source (old `PRIMEoracle`) | `0xDEe5…C307` | $1.03700000 |
| New source (`ClampedOracle` wrapper) | `0x166f…816E3` | ≈ $1.039–1.040 (MRL value at execution time) |

Net effect: **+0.2–0.3% reported price for PRIME** at the switch. Existing PRIME-collateral borrowers gain a tiny LTV cushion; existing PRIME-debt borrowers' debt rises by the same percentage in fiat terms.

### Lowest reportable price (this block, today's pool)

```
Pool EMA = $1.02706907
Band lower = pool × 0.98 = $1.00652769
```

A position whose health factor (computed on current MRL of $1.039) drops to **HF ≤ 1.032** would be liquidatable if the wrapper clamps to the lower band edge in one read. This is a one-block worst-case; in practice MRL or pool would need to move enough to trigger it.

## Deployment + enactment

### Code

- Contract: `contracts/ClampedOracle.sol` (+ interface and dependency interfaces).
- Foundry tests + fuzz: `tests/foundry/ClampedOracle.t.sol` (37 tests; CI runs 10,000 fuzz iterations per property).
- Deploy task: `tasks/misc/deploy-clamped-oracle.ts` (parameterised, one wrapper at a time).
- Proposal task: `tasks/proposals/swap-prime-oracle.ts` (generates the encoded preimage hex + decoded tree).
- Lark enactment task: `tasks/proposals/enact-prime-oracle-lark.ts` (signs the swap as `//Alice` via OpenGov Root track on `node.lark`).

### Mainnet

Wrapper deployed on hydration mainnet at `0x166f286745171D58B6b16E6020f7e48246c816E3` (block ~ when `deploy-clamped-oracle` ran). Swap proposal preimage hex generated and verified; **not yet submitted** through governance.

### Lark (dry-run)

Enacted on `node.lark.hydration.cloud` via OpenGov referendum #340 on the Root track, signed by `//Alice`. Outcome:

- `AaveOracle.getSourceOfAsset(PRIME)` flipped from `0xDEe5…C307` → `0x166f…816E3`.
- `AaveOracle.getAssetPrice(PRIME)` went from `103,700,000` → `103,940,891` (+0.23%).
- Verified `latestAnswer()` on the wrapper matched MRL pass-through (in-band).

## Trend

Run `python3 scripts/prime-oracle-trend.py` to refresh. Latest snapshot (1,116 MRL updates indexed):

```
block      | time UTC         |  MRL ($)   |  Pool ($)  |   diff %  | round
---------------------------------------------------------------------------
11396679   | 2026-02-16 15:17 | 1.016435   |    n/a     |    n/a    |    1
11453217   | 2026-02-21 04:03 | 1.019286   | 1.022314   |  −0.296%  |    2
11789328   | 2026-03-19 21:55 | 1.019286   | 1.024088   |  −0.469%  |    2  ← max negative
11957383   | 2026-04-03 00:27 | 1.019286   | 1.023177   |  −0.380%  |    2
12013402   | 2026-04-07 16:00 | 1.029621   | 1.022950   |  +0.652%  |    3  ← Wormhole resumes
12100288   | 2026-04-15 12:28 | 1.031180   | 1.024101   |  +0.691%  |  106
12239533   | 2026-04-28 11:18 | 1.033678   | 1.025472   |  +0.800%  |  404
12366297   | 2026-05-11 03:34 | 1.036262   | 1.025828   |  +1.017%  |  688
12488254   | 2026-05-23 18:41 | 1.038966   | 1.027522   |  +1.114%  |  979
12548768   | 2026-05-29 15:09 | 1.039981   | 1.027069   |  +1.257%  | 1116  ← current, max positive
```

**Two regimes:**

- **Feb 16 → Apr 7 (50 days, MRL frozen at $1.019286).** Only 2 MRL events in that window. Wormhole/Moonbeam relayer effectively idle. Pool EMA was the only live signal; divergence bounded to ~0.5%.
- **Apr 7 → today (52 days, 1,113 MRL events ≈ 22/day).** Relayer active, MRL ratchets up 5–10 bps per update. Pool drifts but doesn't keep up; gap widens monotonically.

**Operational observations:**

1. `|diff|` never exceeded 1.25% historically. Today's 1.26% is the all-time high.
2. The MRL/pool gap has grown ≈12 bps/week since April. At that rate the band gets breached in **6–8 weeks** if pool doesn't catch up. Either (a) PRIME spot rallies on Hydration to close the gap, (b) MRL stops drifting up, or (c) widen the band.
3. **The 50-day MRL freeze was a real Wormhole quiescence, not a deadband.** No round-3 was pushed even though pool moved 50 bps. A `maxStaleness` parameter would have surfaced this; the current wrapper silently passed through stale MRL the entire time.

## Open items

- **`maxStaleness` on the wrapper.** Today there is no check; a halted Wormhole would freeze MRL indefinitely and the wrapper would clamp-toward-pool forever. Adding `primaryAgg.latestTimestamp()` freshness rejection would surface this as a revert, letting AaveOracle's fallback path (if wired) handle the outage.
- **Mainnet proposal submission.** The encoded preimage hex is ready (see `swap-prime-oracle` task output); needs to be submitted via governance with whatever channel is current.
- **Alerting.** Recommended: monitor `|MRL_latestAnswer − poolEMA_latestAnswer| / poolEMA > 150 bps` and page when crossed. That gives 50 bps of warning before the wrapper starts clamping.
- **Future assets.** Same template applies to other Hydration-native assets with both a push primary and a stableswap/Omnipool secondary. The `deploy-clamped-oracle` task takes those as args; each swap gets its own dedicated proposal task following `swap-prime-oracle.ts` as the template.
