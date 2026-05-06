#!/usr/bin/env bash
# Phase 0.5: fund deployer + whitelist as contract creator. Run after 0.4 settles.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Phase 0.5a: fund deployer (HDX + WETH from Alice) ==="
WS_URL=wss://2.lark.hydration.cloud \
  TARGET=0x222222B60cA97a4998B7D07b99034Fa4d9339531 HDX=1000 WETH=0.5 \
  npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
  scripts/lark/fund-account.ts

echo ""
echo "=== Phase 0.5b: whitelist deployer as contract creator ==="
WS_URL=wss://2.lark.hydration.cloud \
  npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
  scripts/lark/whitelist-deployer.ts

echo ""
echo "=== Phase 0.5 complete ==="
