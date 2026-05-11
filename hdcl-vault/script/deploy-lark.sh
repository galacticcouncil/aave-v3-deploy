#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# E2E deploy script for HDCL Vault on Hydration Lark testnet.
# Designed to be re-run after each lark reset.
#
# Usage:
#   ./script/deploy-lark.sh [RPC_SUBDOMAIN]
#
# Example:
#   ./script/deploy-lark.sh 2        # deploys to 2.lark
#   ./script/deploy-lark.sh 4        # deploys to 4.lark
#   ./script/deploy-lark.sh          # defaults to 2.lark
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(dirname "$SCRIPT_DIR")"

LARK_NUM="${1:-2}"
RPC_HTTP="https://${LARK_NUM}.lark.hydration.cloud"
RPC_WS="wss://${LARK_NUM}.lark.hydration.cloud"

# Alice's EVM credentials (Hydration deployer)
ALICE_PK="0xd9b59470b079ffd6a0373c0870dcf7faf8c20f7340b6d05acbeb8a8a8473b131"
ALICE_ADDR="0x222222B60cA97a4998B7D07b99034Fa4d9339531"

# Funding amounts (whole units)
WETH_AMOUNT="${WETH_AMOUNT:-1}"   # WETH for EVM gas (18 decimals)
HDX_AMOUNT="${HDX_AMOUNT:-100}"   # HDX for Substrate fees (12 decimals)

echo "============================================"
echo " HDCL Vault deploy → ${LARK_NUM}.lark"
echo "============================================"
echo "RPC HTTP: $RPC_HTTP"
echo "RPC WS:   $RPC_WS"
echo "Deployer: $ALICE_ADDR"
echo ""

# ----------------------------------------------------------
# Step 0: Check tooling
# ----------------------------------------------------------
command -v forge >/dev/null 2>&1 || { echo "forge not found. Install foundry first."; exit 1; }
command -v cast  >/dev/null 2>&1 || { echo "cast not found. Install foundry first."; exit 1; }
command -v node  >/dev/null 2>&1 || { echo "node not found."; exit 1; }

# ----------------------------------------------------------
# Step 1: Fund Alice's EVM address from Substrate
# ----------------------------------------------------------
echo "--- Step 1: Fund EVM address from Substrate ---"

BALANCE_WEI=$(cast balance "$ALICE_ADDR" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "0")
echo "Current EVM balance: $BALANCE_WEI wei"

if [ "$BALANCE_WEI" = "0" ]; then
  echo "EVM balance is 0 — funding from Substrate..."

  # Install @polkadot/api if needed (temporary, in script dir)
  FUND_SCRIPT="$SCRIPT_DIR/fund-evm.mjs"
  if [ ! -d "$SCRIPT_DIR/node_modules/@polkadot" ]; then
    echo "Installing @polkadot/api (one-time)..."
    (cd "$SCRIPT_DIR" && npm install --no-save @polkadot/api@latest 2>&1 | tail -1)
  fi

  node "$FUND_SCRIPT" --rpc "$RPC_WS" --evm-address "$ALICE_ADDR" --weth "$WETH_AMOUNT" --hdx "$HDX_AMOUNT"

  # Verify
  NEW_BALANCE=$(cast balance "$ALICE_ADDR" --rpc-url "$RPC_HTTP" --ether 2>/dev/null || echo "0")
  echo "New EVM balance: $NEW_BALANCE ETH"
else
  echo "EVM already funded, skipping."
fi

# ----------------------------------------------------------
# Step 2: Deploy HDCL Vault
# ----------------------------------------------------------
echo ""
echo "--- Step 2: Deploy HDCL Vault ---"

cd "$VAULT_DIR"

# Temporarily override rpc in foundry.toml isn't needed — we pass --rpc-url directly
ADMIN_ADDRESS="$ALICE_ADDR" \
PRIVATE_KEY="$ALICE_PK" \
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_HTTP" \
  --broadcast \
  --evm-version london \
  --legacy \
  --slow \
  --gas-estimate-multiplier 300 \
  2>&1 | tee /tmp/hdcl-deploy-output.txt

# Extract deployed addresses
IMPL_ADDR=$(grep "Implementation:" /tmp/hdcl-deploy-output.txt | awk '{print $NF}')
PROXY_ADDR=$(grep "Proxy (HDCL Vault):" /tmp/hdcl-deploy-output.txt | awk '{print $NF}')
ORACLE_ADDR=$(grep "WDCLOracle:" /tmp/hdcl-deploy-output.txt | awk '{print $NF}')

echo ""
echo "============================================"
echo " Deployment complete!"
echo "============================================"
echo "Network:        ${LARK_NUM}.lark (chain 222222)"
echo "Implementation: $IMPL_ADDR"
echo "Proxy (Vault):  $PROXY_ADDR"
echo "WDCLOracle:     $ORACLE_ADDR"
echo "Admin:          $ALICE_ADDR"
echo ""
echo "Keeper config:"
echo "  RPC_URL=$RPC_HTTP"
echo "  VAULT_ADDRESS=$PROXY_ADDR"
echo "  ORACLE_ADDRESS=$ORACLE_ADDR"
echo "  KEEPER_PRIVATE_KEY=$ALICE_PK"
echo "============================================"
