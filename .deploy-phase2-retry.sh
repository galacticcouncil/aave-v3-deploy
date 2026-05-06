#!/usr/bin/env bash
# Auto-retry Phase 2 (core market deploy) until it succeeds or hits 8 attempts.
cd "$(dirname "$0")"
MAX=8
for i in $(seq 1 $MAX); do
  echo ""
  echo "============================================="
  echo "  Phase 2 attempt $i/$MAX"
  echo "============================================="
  if MARKET_NAME=GIGAHDX FORK=hydration RPC=https://2.lark.hydration.cloud \
     PRIV_KEY=0xd9b59470b079ffd6a0373c0870dcf7faf8c20f7340b6d05acbeb8a8a8473b131 \
     npx hardhat deploy --tags market --network lark2; then
    echo ""
    echo "============================================="
    echo "  Phase 2 SUCCESS on attempt $i"
    echo "============================================="
    exit 0
  fi
  echo "attempt $i hit nonce/gas error — sleeping 8s then retrying"
  sleep 8
done
echo "Phase 2 FAILED after $MAX attempts"
exit 1
