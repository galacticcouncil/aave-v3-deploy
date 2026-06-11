#!/usr/bin/env bash
#
# GIGAHDX deployment — the real mainnet procedure, run against a lark.
#
# This runs ONLY the deployment steps that exist on mainnet, in the same order.
# It does NOT bootstrap the testnet: the GIGAHDX runtime must already be live and
# the deployer must already be funded (WETH = EVM gas) and whitelisted as a
# contract creator. Those are preconditions on mainnet too — the preflight
# VERIFIES them and aborts if missing, rather than performing any testnet setup.
#
# Governance is handled MANUALLY: the final step generates and PRINTS the
# launch proposal preimage (encoded call + decoded tree) but submits nothing.
# You take that hex and submit/enact the referendum yourself, then verify.
#
# Usage:
#   N=0 scripts/lark/deploy-all.sh                # deploy to 0.lark
#   N=0 ASSUME_YES=1 scripts/lark/deploy-all.sh   # skip the confirm prompt
#
# Re-runnable: every step is idempotent (hardhat-deploy resumes; the proposal
# script checks on-chain state and skips what's already applied).

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
N="${N:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

HOLLAR_DIR="../hollar"

export WS_URL="wss://${N}.lark.hydration.cloud"
export RPC="https://${N}.lark.hydration.cloud"
export RPC_URL="https://${N}.lark.hydration.cloud"
export PRIV_KEY="0xd9b59470b079ffd6a0373c0870dcf7faf8c20f7340b6d05acbeb8a8a8473b131"
export MARKET_NAME="GIGAHDX"
export FORK="hydration"

DEPLOYER_EVM="0x222222B60cA97a4998B7D07b99034Fa4d9339531"
NETWORK="lark2"            # hardhat network NAME; endpoint comes from $RPC (→ N.lark)
LARK_SENTINEL="deployments/lark2/.lark-number"
GIGAHDXS_PRECOMPILE="0x0000010267696761686478730000029e00000000"  # stHDX/HDX gigahdxs source

GHO_DEPLOY_TAG="${GHO_DEPLOY_TAG:-gigahdx_gho_deploy}"

CORE_ARTIFACTS=(
  Pool-Proxy-GIGAHDX.json Pool-Implementation.json
  PoolAddressesProvider-GIGAHDX.json PoolAddressesProviderRegistry.json
  PoolConfigurator-Implementation.json PoolConfigurator-Proxy-GIGAHDX.json
  ACLManager-GIGAHDX.json AaveOracle-GIGAHDX.json TreasuryProxy.json
)
GHO_ARTIFACTS=(
  GhoAToken-GIGAHDX GhoStableDebtToken-GIGAHDX
  GhoVariableDebtToken-GIGAHDX GhoInterestRateStrategy-GIGAHDX
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
phase() { printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"; }
info()  { printf '\033[0;32m• %s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m! %s\033[0m\n' "$*"; }
die()   { printf '\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run_ts() { npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' "$@"; }

rpc_call() {
  curl -s --max-time 15 "$RPC" -X POST -H 'content-type: application/json' --data "$1"
}

retry() {
  local max="$1"; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$max" ]; then die "failed after $max attempts: $*"; fi
    warn "attempt $n/$max failed, retrying: $*"; n=$((n + 1)); sleep 3
  done
}

# ---------------------------------------------------------------------------
# Preflight — verify preconditions (do not bootstrap)
# ---------------------------------------------------------------------------
phase "Preflight — target ${N}.lark"
info "EVM RPC : $RPC"
info "deployer: $DEPLOYER_EVM"

[ -d "$HOLLAR_DIR" ] || die "hollar repo not found at $HOLLAR_DIR (needed for GHO impls)"
grep -q "lark2" "$HOLLAR_DIR/hardhat.config.ts" 2>/dev/null \
  || die "hollar/hardhat.config.ts does not register the 'lark2' network"
[ -d "$HOLLAR_DIR/node_modules/hardhat" ] \
  || die "hollar deps not installed — run 'cd $HOLLAR_DIR && npm install' first (step 4 needs a local hardhat)"
[ -d "$HOLLAR_DIR/types" ] \
  || die "hollar not compiled — run 'cd $HOLLAR_DIR && npm run compile:hh' (GHO deploy imports typechain ../types)"

# 1) GIGAHDX runtime must be live (node-team prerequisite, not a deploy step).
runtime_check="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$GIGAHDXS_PRECOMPILE\",\"data\":\"0x50d25bcd\"},\"latest\"]}")"
echo "$runtime_check" | grep -q "Price not available" \
  && die "GIGAHDX runtime NOT live on ${N}.lark. It's a prerequisite (node team) — get it live first."
info "GIGAHDX runtime present"

# 2) Deployer must already hold gas (WETH is the EVM fee asset) — a precondition,
#    not a step. Fund + whitelist it out of band if this fails.
bal="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_EVM\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
[ -n "$bal" ] && [ "$bal" != "0x0" ] \
  || die "deployer $DEPLOYER_EVM has no gas (WETH) on ${N}.lark.
       Fund it and whitelist it as a contract creator first — these are
       preconditions, not deployment steps."
info "deployer funded (balance $bal)"

# Guard against deploying over another lark's artifacts (all larks = chainId 222222).
if [ -f "$LARK_SENTINEL" ]; then
  prev="$(cat "$LARK_SENTINEL")"
  [ "$prev" = "$N" ] || die "deployments/${NETWORK}/ holds lark ${prev} artifacts, not ${N}.
       Clear it first:  rm -rf deployments/${NETWORK}/"
fi

if [ "${ASSUME_YES:-}" != "1" ]; then
  read -r -p "Deploy GIGAHDX to ${N}.lark? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "aborted"
fi

mkdir -p "deployments/${NETWORK}"
echo "$N" > "$LARK_SENTINEL"

# ===========================================================================
# The deployment
# ===========================================================================

phase "1 — deploy core market (EVM)"
retry 5 npx hardhat deploy --tags market --network "$NETWORK"

phase "2 — deploy LockableAToken impl"
retry 3 npx hardhat deploy-LockableAToken --network "$NETWORK"

phase "3 — deploy the stHDX USDOracleAdapter (real Omnipool-EMA oracle)"
info "legs from markets/gigahdx: assetToX=gigahdxs, xToUSD=Omnipool EMA Day"
retry 3 npx hardhat deploy-USDOracleAdapter --oracle STHDX --network "$NETWORK"
info "init-reserve auto-wires STHDX-USDOracleAdapter as the stHDX source"

phase "4 — deploy GHO impls (in hollar) + import"
mkdir -p "$HOLLAR_DIR/deployments/lark2"
echo "222222" > "$HOLLAR_DIR/deployments/lark2/.chainId"
# Clear stale GHO impl artifacts + migration entries so they actually redeploy
# to THIS lark (hardhat-deploy keys by chainId 222222, shared across all larks).
rm -f "$HOLLAR_DIR/deployments/lark2/"Gho*-GIGAHDX.json "$HOLLAR_DIR/deployments/lark2/.migrations.json"
for f in "${CORE_ARTIFACTS[@]}"; do
  [ -f "deployments/${NETWORK}/$f" ] || die "missing core artifact deployments/${NETWORK}/$f (did step 1 finish?)"
  cp "deployments/${NETWORK}/$f" "$HOLLAR_DIR/deployments/lark2/"
done
cp "deployments/hydration/HOLLAR.json" "$HOLLAR_DIR/deployments/lark2/GhoToken.json"

# CRITICAL: do NOT pass FORK here. hollar enters *fork mode* when FORK is set,
# which deploys the GHO impls to a throwaway local fork instead of the lark —
# leaving phantom impl addresses on-chain and bricking initReserves(HOLLAR)
# with "Cannot set a proxy implementation to a non-contract address".
( cd "$HOLLAR_DIR" \
  && MARKET_NAME=GIGAHDX FORK= RPC="$RPC" PRIV_KEY="$PRIV_KEY" \
     retry 3 npx hardhat deploy --tags "$GHO_DEPLOY_TAG" --network lark2 ) \
  || die "hollar GHO deploy failed"

# Sanity: the deployed GhoAToken impl must actually have code on this lark.
gho_impl="$(node -e "console.log(require('$HOLLAR_DIR/deployments/lark2/GhoAToken-GIGAHDX.json').address)" 2>/dev/null || true)"
if [ -n "$gho_impl" ]; then
  code="$(curl -s "$RPC" -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$gho_impl\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
  [ -n "$code" ] && [ "$code" != "0x" ] || die "GhoAToken impl $gho_impl has NO CODE on ${N}.lark — GHO deploy went to a fork/wrong chain"
  info "GhoAToken impl on-chain at $gho_impl ✓"
fi

for f in "${GHO_ARTIFACTS[@]}"; do
  [ -f "$HOLLAR_DIR/deployments/lark2/$f.json" ] || die "hollar did not produce $f.json"
  cp "$HOLLAR_DIR/deployments/lark2/$f.json" "deployments/${NETWORK}/$f.json"
done
cp "deployments/hydration/HOLLAR.json"                 "deployments/${NETWORK}/"
cp "deployments/hydration/ZeroDiscountRateStrategy.json" "deployments/${NETWORK}/"

phase "5 — transfer admin to governance (deployer EOA; enables the proposal's ACL checks)"
# idempotent (skips already-granted roles); retry absorbs transient lark 'nonce too low'
retry 6 npx hardhat run scripts/lark/transfer-admin-to-governance.ts --network "$NETWORK"
retry 4 npx hardhat run scripts/lark/grant-risk-admin.ts --network "$NETWORK"

phase "6 — generate the launch proposal preimage (MANUAL submission)"
info "one batch: init + config + HOLLAR + facilitator + asset registry +"
info "gigaHdx.setPoolContract + evmAccounts.approveContract"
info "This PRINTS the encoded preimage hex + decoded tree and submits NOTHING."
info "Take the 'submit preimages' hex below and submit it as a referendum yourself."
npx hardhat gigahdx-launch --network "$NETWORK"

# ===========================================================================
# Address sheet (read-only)
# ===========================================================================
phase "7 — generate the address sheet"
npx hardhat run scripts/lark/generate-addresses.ts --network "$NETWORK"

phase "DONE — contracts deployed to ${N}.lark; proposal preimage printed in Phase 6"
info "next: submit the Phase 6 preimage hex as a referendum manually and enact it,"
info "then come back and I'll verify (or run scripts/lark/verify-readiness.ts)"
