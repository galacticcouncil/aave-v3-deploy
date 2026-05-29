#!/usr/bin/env python3
"""
PRIME oracle trend: pull every MRL update event from Hydration's indexer
(grafana-api.play.hydration.cloud), sample the PRIME/HOLLAR pool 10-min EMA at
each MRL block via mainnet RPC, and print the divergence over time.

Used to verify the ClampedOracle (MRL primary, pool EMA secondary, 200 bps)
stays in-band historically and to gauge how fast the band is being approached.

Usage:
    python3 scripts/prime-oracle-trend.py

Deps: python3 + `cast` (foundry) on PATH. No project deps; safe to run anywhere.
"""

import bisect
import datetime
import json
import subprocess
import sys
import urllib.request

# Hydration indexer (HydraDX Firesquid postgres via Grafana datasource proxy).
GRAFANA = "https://grafana-api.play.hydration.cloud/api/ds/query"
DS_UID = "OulRfMKVz"

# Mainnet RPC -- only used for the pool EMA precompile, which doesn't emit events.
RPC = "https://rpc.hydradx.cloud"

# Feeds.
MRL = "0x82022F77ae239Ad99bB1F2aC0d8DaFF6Cc976a07"     # ManagedOracle, PRIME/USD primary
POOL = "0x00000102737461626c6573770000008f0000002b"   # stableswap 10-min EMA, PRIME/HOLLAR
# AnswerUpdated(int256 current, uint256 indexed roundId, uint256 updatedAt).
ANSWER_UPDATED_TOPIC0 = "0x7d8cee5d1217e47a14a662098e84a7758580aaf78f430c07c543249234e867bf"

# Sampling parameters.
TIME_SAMPLES = 30        # evenly across MRL deploy → now
GAP_FILL = 10            # extra samples inside the longest no-update window


def gquery(sql):
    body = json.dumps({
        "queries": [{
            "refId": "A",
            "datasource": {"uid": DS_UID, "type": "postgres"},
            "rawSql": sql,
            "format": "table",
        }],
    }).encode()
    req = urllib.request.Request(GRAFANA, data=body, headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    res = r["results"]["A"]
    if res.get("error"):
        sys.exit(f"grafana err: {res['error']}")
    return res["frames"][0]["data"]["values"]


def pool_at(block):
    try:
        out = subprocess.check_output(
            ["cast", "call", POOL, "latestAnswer()(int256)", "--rpc-url", RPC, "--block", str(block)],
            timeout=15, stderr=subprocess.STDOUT, text=True,
        ).strip().split()[0]
        return int(out)
    except subprocess.CalledProcessError:
        return None


def main():
    cols = gquery(f"""
        SELECT b.height, b.timestamp,
          ('x' || substr(f.topic1, length(f.topic1) - 15, 16))::bit(64)::bigint AS rid,
          ('x' || substr((e.args->'log'->>'data'), 51, 16))::bit(64)::bigint AS answer
        FROM frontier_evm_log f
        JOIN event e ON e.id = f.event_id
        JOIN block b ON b.id = e.block_id
        WHERE f.contract = LOWER('{MRL}')
          AND f.topic0 = '{ANSWER_UPDATED_TOPIC0}'
        ORDER BY b.height
    """)
    heights, tsms, rounds, answers = cols
    n = len(heights)
    print(f"# {n} MRL updates from block {heights[0]} to {heights[-1]}", file=sys.stderr)

    # Latest MRL value as of any block (carry-forward).
    def mrl_at(block):
        i = bisect.bisect_right(heights, block) - 1
        return (rounds[i], answers[i]) if i >= 0 else (None, None)

    # Time-uniform samples, picking the nearest MRL update.
    t0, t1 = tsms[0], tsms[-1]
    samples = set()
    for i in range(TIME_SAMPLES + 1):
        target_ts = t0 + i * (t1 - t0) / TIME_SAMPLES
        idx = min(bisect.bisect_left(tsms, target_ts), n - 1)
        samples.add(heights[idx])

    # Find the longest gap between consecutive MRL updates and fill it
    # with synthetic sample blocks so the flat period isn't compressed away.
    longest = max(range(n - 1), key=lambda i: heights[i + 1] - heights[i])
    b_lo, b_hi = heights[longest], heights[longest + 1]
    for k in range(1, GAP_FILL + 1):
        samples.add(int(b_lo + k * (b_hi - b_lo) / (GAP_FILL + 1)))

    samples = sorted(samples)

    print(f"\n{'block':>10} | {'time UTC':16} | {'MRL ($)':>10} | {'Pool ($)':>10} | {'diff %':>9} | round")
    print("-" * 75)
    for blk in samples:
        rid, m = mrl_at(blk)
        if m is None:
            continue
        if blk in heights:
            ts = tsms[heights.index(blk)]
        else:
            try:
                ts_raw = subprocess.check_output(
                    ["cast", "block", str(blk), "--rpc-url", RPC, "--field", "timestamp"],
                    timeout=10, text=True,
                ).strip()
                ts = int(ts_raw) * 1000
            except subprocess.CalledProcessError:
                continue
        tstr = datetime.datetime.fromtimestamp(ts / 1000, tz=datetime.UTC).strftime("%Y-%m-%d %H:%M")
        pool = pool_at(blk)
        if pool is None:
            print(f"{blk:>10} | {tstr:16} | {m / 1e8:>10.6f} | {'n/a':>10} | {'n/a':>9} | {rid}")
            continue
        diff_pct = (m - pool) / pool * 100
        print(f"{blk:>10} | {tstr:16} | {m / 1e8:>10.6f} | {pool / 1e8:>10.6f} | {diff_pct:>+8.3f}% | {rid}")


if __name__ == "__main__":
    main()
