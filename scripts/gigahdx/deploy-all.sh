#!/usr/bin/env bash
#
# GIGAHDX deployment — the real mainnet procedure.
#
# Runs ONLY the deployment steps that exist on mainnet, in the same order.
# It does NOT bootstrap anything: the GIGAHDX runtime must already be live and
# the deployer must already be funded (WETH = EVM gas) and whitelisted as a
# contract creator. The preflight VERIFIES those preconditions and aborts if
# missing, rather than performing any setup.
#
# Governance is handled MANUALLY: the final step generates and PRINTS the
# launch proposal preimage (encoded call + decoded tree) but submits nothing.
# You take that hex and submit/enact the referendum yourself, then verify.
#
# ---------------------------------------------------------------------------
# Target selection (env)
# ---------------------------------------------------------------------------
#   RPC      EVM RPC endpoint. If unset, defaults to the lark for ${N} (testnet):
#            https://${N}.lark.hydration.cloud . Set it to a mainnet endpoint
#            (e.g. https://rpc.hydradx.cloud) to deploy to mainnet.
#   PK       Deployer private key (0x...). REQUIRED for mainnet. On a *.lark
#            endpoint it falls back to the built-in lark test key.
#   NETWORK  hardhat network name. Auto: "lark2" for lark, "hydration" for mainnet.
#   WS_URL   Substrate WS endpoint. Auto-derived from RPC (http→ws) if unset.
#   DEPLOYER_EVM  Derived from PK by default; override to skip derivation.
#
# Usage:
#   # mainnet
#   RPC=https://rpc.hydradx.cloud PK=0x... scripts/gigahdx/deploy-all.sh
#   RPC=https://rpc.hydradx.cloud PK=0x... ASSUME_YES=1 scripts/gigahdx/deploy-all.sh
#
#   # lark (testnet), unchanged behaviour
#   N=0 scripts/gigahdx/deploy-all.sh
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

# RPC: explicit env wins; otherwise default to the lark for ${N}.
DEFAULT_LARK_RPC="https://${N}.lark.hydration.cloud"
export RPC="${RPC:-$DEFAULT_LARK_RPC}"
export RPC_URL="${RPC_URL:-$RPC}"
export WS_URL="${WS_URL:-$(printf '%s' "$RPC" | sed 's#^http#ws#')}"

# Lark (testnet) mode is OPT-IN: set IS_LARK=1 explicitly to deploy to a lark
# (enables the lark test-key fallback, GHO force-redeploy, and sentinel). Anything
# else — including a *.lark host used as a real target — is treated as mainnet:
# PK is required (no public-test-key fallback) and GHO impls resume, not re-clear.
IS_LARK="${IS_LARK:-0}"

# Deployer key: PK (preferred) or PRIV_KEY. On a lark, fall back to the test key.
PRIV_KEY="${PK:-${PRIV_KEY:-}}"
if [ -z "$PRIV_KEY" ]; then
  if [ "$IS_LARK" = "1" ]; then
    PRIV_KEY="0xd9b59470b079ffd6a0373c0870dcf7faf8c20f7340b6d05acbeb8a8a8473b131"
  else
    echo "ERROR: set PK=0x... (deployer private key) for mainnet deployment" >&2
    exit 1
  fi
fi
export PRIV_KEY

export MARKET_NAME="GIGAHDX"

# NETWORK = target hardhat network (= deployments dir). Lark defaults to lark2;
# mainnet to hydration. Honor an explicit override (e.g. NETWORK=gigahdx).
if [ "$IS_LARK" = "1" ]; then
  NETWORK="${NETWORK:-lark2}"
else
  NETWORK="${NETWORK:-hydration}"
fi

# FORK drives both fork-mode AND config/deployment-dir resolution
# (`FORK ? FORK : hre.network.name`). It's ONLY needed when the target NETWORK has
# no GIGAHDX market-config keys of its own — lark2/nice/zombie resolve config via
# FORK=hydration. Networks that DO carry gigahdx keys (gigahdx, hydration) MUST run
# with FORK empty; otherwise address lookups in phase 6 (review-reserve-factors,
# init-reserve) read deployments/hydration instead of deployments/$NETWORK — the
# split-brain that makes getAllReservesTokens() revert on a stale provider address.
case "$NETWORK" in
  hydration|gigahdx) export FORK="${FORK:-}" ;;
  *)                 export FORK="${FORK:-hydration}" ;;
esac

# Where the canonical HOLLAR token + ZeroDiscountRateStrategy artifacts live.
HYDRATION_DEPLOYMENTS="deployments/hydration"
# hollar deploys GHO impls under this network/dir (mirrors $NETWORK by default).
HOLLAR_NETWORK="${HOLLAR_NETWORK:-$NETWORK}"
HOLLAR_DEPLOY_DIR="$HOLLAR_DIR/deployments/$HOLLAR_NETWORK"

LARK_SENTINEL="deployments/${NETWORK}/.lark-number"
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

# Chain-wide singletons reused from the existing Hydration deployment instead of
# redeployed. Safe because they carry no market-specific immutable (the logic
# libraries differ only by their cross-link addresses, so reusing the whole set
# stays consistent; ReservesSetupHelper is stateless). Seeded into the target
# deployments dir before phase 1 so hardhat-deploy reuses them and links the
# fresh Pool/PoolConfigurator impls against the existing libs. Disable with
# REUSE_HYDRATION_SINGLETONS=0. (Pool/Configurator impls, ACL, oracle, rate
# strategies and aToken/debt impls are NOT reusable — they bake in the provider/pool.)
REUSE_HYDRATION_SINGLETONS="${REUSE_HYDRATION_SINGLETONS:-1}"
REUSABLE_ARTIFACTS=(
  SupplyLogic BorrowLogic LiquidationLogic EModeLogic
  BridgeLogic ConfiguratorLogic FlashLoanLogic PoolLogic
  ReservesSetupHelper
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

# Derive the deployer EVM address from PK so the preflight checks the account we
# actually deploy with (catches a key/whitelist mismatch). Falls back to the
# known GIGAHDX deployer if ethers isn't resolvable.
if [ -z "${DEPLOYER_EVM:-}" ]; then
  DEPLOYER_EVM="$(PRIV_KEY="$PRIV_KEY" node -e \
    "const e=require('ethers');const W=e.Wallet||e.ethers.Wallet;console.log(new W(process.env.PRIV_KEY).address)" \
    2>/dev/null || true)"
  [ -n "$DEPLOYER_EVM" ] || DEPLOYER_EVM="0x222222B60cA97a4998B7D07b99034Fa4d9339531"
fi

TARGET_DESC="$([ "$IS_LARK" = "1" ] && echo "${N}.lark" || echo "mainnet ($RPC)")"

# ---------------------------------------------------------------------------
# Preflight — verify preconditions (do not bootstrap)
# ---------------------------------------------------------------------------
phase "Preflight — target ${TARGET_DESC}"
info "EVM RPC : $RPC"
info "network : $NETWORK   (FORK='${FORK}')"
info "deployer: $DEPLOYER_EVM"

[ -d "$HOLLAR_DIR" ] || die "hollar repo not found at $HOLLAR_DIR (needed for GHO impls)"
grep -q "$HOLLAR_NETWORK" "$HOLLAR_DIR/hardhat.config.ts" 2>/dev/null \
  || die "hollar/hardhat.config.ts does not register the '$HOLLAR_NETWORK' network"
[ -d "$HOLLAR_DIR/node_modules/hardhat" ] \
  || die "hollar deps not installed — run 'cd $HOLLAR_DIR && npm install' first (step 4 needs a local hardhat)"
[ -d "$HOLLAR_DIR/types" ] \
  || die "hollar not compiled — run 'cd $HOLLAR_DIR && npm run compile:hh' (GHO deploy imports typechain ../types)"

# 1) GIGAHDX runtime must be live (node-team prerequisite, not a deploy step).
runtime_check="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$GIGAHDXS_PRECOMPILE\",\"data\":\"0x50d25bcd\"},\"latest\"]}")"
echo "$runtime_check" | grep -q "Price not available" \
  && die "GIGAHDX runtime NOT live on ${TARGET_DESC}. It's a prerequisite (node team) — get it live first."
info "GIGAHDX runtime present"

# 2) Deployer must already hold gas (WETH is the EVM fee asset) — a precondition,
#    not a step. Fund + whitelist it out of band if this fails.
bal="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_EVM\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
[ -n "$bal" ] && [ "$bal" != "0x0" ] \
  || die "deployer $DEPLOYER_EVM has no gas (WETH) on ${TARGET_DESC}.
       Fund it and whitelist it as a contract creator first — these are
       preconditions, not deployment steps."
info "deployer funded (balance $bal)"

# Lark-only: guard against deploying over another lark's artifacts (all larks =
# chainId 222222, so the deployments/lark2 dir is reused). Not relevant to mainnet.
if [ "$IS_LARK" = "1" ] && [ -f "$LARK_SENTINEL" ]; then
  prev="$(cat "$LARK_SENTINEL")"
  [ "$prev" = "$N" ] || die "deployments/${NETWORK}/ holds lark ${prev} artifacts, not ${N}.
       Clear it first:  rm -rf deployments/${NETWORK}/"
fi

if [ "${ASSUME_YES:-}" != "1" ]; then
  read -r -p "Deploy GIGAHDX to ${TARGET_DESC}? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "aborted"
fi

mkdir -p "deployments/${NETWORK}"
[ "$IS_LARK" = "1" ] && echo "$N" > "$LARK_SENTINEL"

# ---------------------------------------------------------------------------
# Reuse chain-wide singletons from the existing Hydration deployment
# ---------------------------------------------------------------------------
# Seed the target deployments dir with the reusable artifacts so hardhat-deploy
# reuses them (matches on-chain bytecode) instead of redeploying. txHash/receipt
# are stripped so a chopsticks fork doesn't hang fetching a historical tx in
# fetchIfDifferent (harmless on real mainnet, where the tx is fetchable).
if [ "$REUSE_HYDRATION_SINGLETONS" = "1" ] && [ "deployments/${NETWORK}" != "$HYDRATION_DEPLOYMENTS" ]; then
  phase "0.5 — reuse Hydration singletons (logic libraries + helpers)"
  [ -f "deployments/${NETWORK}/.chainId" ] || cp "$HYDRATION_DEPLOYMENTS/.chainId" "deployments/${NETWORK}/.chainId" 2>/dev/null || echo "222222" > "deployments/${NETWORK}/.chainId"
  reused=0
  for f in "${REUSABLE_ARTIFACTS[@]}"; do
    src="$HYDRATION_DEPLOYMENTS/$f.json"
    [ -f "$src" ] || { warn "reusable artifact $f.json not found in $HYDRATION_DEPLOYMENTS — will deploy fresh"; continue; }
    node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync('$src'));delete j.transactionHash;delete j.receipt;fs.writeFileSync('deployments/${NETWORK}/$f.json',JSON.stringify(j,null,2));"
    info "reusing $f at $(node -e "console.log(require('./deployments/${NETWORK}/$f.json').address)")"
    reused=$((reused + 1))
  done
  info "seeded $reused reusable singleton(s) — hardhat-deploy will reuse, not redeploy"
fi

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
mkdir -p "$HOLLAR_DEPLOY_DIR"
echo "222222" > "$HOLLAR_DEPLOY_DIR/.chainId"
if [ "$IS_LARK" = "1" ]; then
  # Lark-only: clear stale GHO impl artifacts + migration entries so they actually
  # redeploy to THIS lark (hardhat-deploy keys by chainId 222222, shared across
  # all larks). On mainnet there's a single target — keep state so re-runs resume.
  rm -f "$HOLLAR_DEPLOY_DIR/"Gho*-GIGAHDX.json "$HOLLAR_DEPLOY_DIR/.migrations.json"
fi
for f in "${CORE_ARTIFACTS[@]}"; do
  [ -f "deployments/${NETWORK}/$f" ] || die "missing core artifact deployments/${NETWORK}/$f (did step 1 finish?)"
  cp "deployments/${NETWORK}/$f" "$HOLLAR_DEPLOY_DIR/"
done
cp "$HYDRATION_DEPLOYMENTS/HOLLAR.json" "$HOLLAR_DEPLOY_DIR/GhoToken.json"

# CRITICAL: do NOT pass FORK here. hollar enters *fork mode* when FORK is set,
# which deploys the GHO impls to a throwaway local fork instead of the live
# network — leaving phantom impl addresses on-chain and bricking
# initReserves(HOLLAR) with "Cannot set a proxy implementation to a non-contract
# address".
( cd "$HOLLAR_DIR" \
  && MARKET_NAME=GIGAHDX FORK= RPC="$RPC" PRIV_KEY="$PRIV_KEY" \
     retry 3 npx hardhat deploy --tags "$GHO_DEPLOY_TAG" --network "$HOLLAR_NETWORK" ) \
  || die "hollar GHO deploy failed"

# Sanity: the deployed GhoAToken impl must actually have code on this network.
gho_impl="$(node -e "console.log(require('$HOLLAR_DEPLOY_DIR/GhoAToken-GIGAHDX.json').address)" 2>/dev/null || true)"
if [ -n "$gho_impl" ]; then
  code="$(curl -s "$RPC" -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$gho_impl\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
  [ -n "$code" ] && [ "$code" != "0x" ] || die "GhoAToken impl $gho_impl has NO CODE on ${TARGET_DESC} — GHO deploy went to a fork/wrong chain"
  info "GhoAToken impl on-chain at $gho_impl ✓"
fi

for f in "${GHO_ARTIFACTS[@]}"; do
  [ -f "$HOLLAR_DEPLOY_DIR/$f.json" ] || die "hollar did not produce $f.json"
  cp "$HOLLAR_DEPLOY_DIR/$f.json" "deployments/${NETWORK}/$f.json"
done
# Pull the canonical HOLLAR token + ZeroDiscountRateStrategy into the target
# network dir. Skip when the target IS deployments/hydration (source == dest).
if [ "deployments/${NETWORK}" != "$HYDRATION_DEPLOYMENTS" ]; then
  cp "$HYDRATION_DEPLOYMENTS/HOLLAR.json"                  "deployments/${NETWORK}/"
  cp "$HYDRATION_DEPLOYMENTS/ZeroDiscountRateStrategy.json" "deployments/${NETWORK}/"
fi

phase "5 — hand over admin to governance, then fully revoke the deployer"
# idempotent (skips already-granted/revoked roles); retry absorbs transient 'nonce too low'
# 1) grant governance every role + transfer Ownable contracts to gov
retry 6 npx hardhat run scripts/gigahdx/transfer-admin-to-governance.ts --network "$NETWORK"
# 2) grant risk admin to the ReservesSetupHelper (needs the deployer's DEFAULT_ADMIN)
retry 4 npx hardhat run scripts/gigahdx/grant-risk-admin.ts --network "$NETWORK"
# 3) LAST: deployer renounces every role it still holds (gov is now sole admin).
#    Has a safety guard that refuses to run unless gov already holds DEFAULT_ADMIN+POOL_ADMIN.
retry 4 npx hardhat run scripts/gigahdx/revoke-deployer.ts --network "$NETWORK"

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
npx hardhat run scripts/gigahdx/generate-addresses.ts --network "$NETWORK"

phase "DONE — contracts deployed to ${TARGET_DESC}; proposal preimage printed in Phase 6"
info "next: submit the Phase 6 preimage hex as a referendum manually and enact it,"
info "then come back and I'll verify (or run scripts/gigahdx/verify-readiness.ts)"
