#!/usr/bin/env bash
#
# BIL deployment — the real mainnet procedure.
#
# Runs ONLY the deployment steps that exist on mainnet, in the same order.
# It does NOT bootstrap anything: the deployer must already be funded
# (WETH = EVM gas) and whitelisted as a contract creator. The preflight
# VERIFIES those preconditions and aborts if missing, rather than performing
# any setup.
#
# Governance is handled MANUALLY: the final step generates and PRINTS the
# launch proposal preimage (encoded call + decoded tree) but submits nothing.
# You take that hex and submit/enact the referendum yourself, then verify.
#
# Lark / chopsticks forks are treated EXACTLY the same as mainnet — only the
# RPC env differs. The deployer key is provided via PK in all cases. No
# special-case lark mode, no test-key fallback.
#
# ---------------------------------------------------------------------------
# Target selection (env)
# ---------------------------------------------------------------------------
#   RPC      EVM RPC endpoint. REQUIRED. Examples:
#              mainnet:   https://rpc.hydradx.cloud
#              lark-2:    https://2.lark.hydration.cloud
#              chopsticks http://localhost:8000
#   PK       Deployer private key (0x...). REQUIRED.
#   NETWORK  hardhat network name. Default: "hydration" (uses
#            deployments/hydration). Override e.g. NETWORK=lark2 to write
#            artifacts to deployments/lark2/.
#   WS_URL   Substrate WS endpoint. Auto-derived from RPC (http→ws) if unset.
#   DEPLOYER_EVM  Derived from PK by default; override to skip derivation.
#
# Usage:
#   # mainnet
#   RPC=https://rpc.hydradx.cloud PK=0x... scripts/bil/deploy-all.sh
#
#   # lark-2 (or any RPC; just point + supply key)
#   RPC=https://2.lark.hydration.cloud NETWORK=lark2 PK=0x... scripts/bil/deploy-all.sh
#
#   # chopsticks mainnet-fork (dry-run; uses hardhat-dev #0 by default)
#   RPC=http://localhost:8000 NETWORK=chopsticks PK=0xac0974… scripts/bil/deploy-all.sh
#
# Re-runnable: every step is idempotent (hardhat-deploy resumes; the proposal
# script checks on-chain state and skips what's already applied).

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

HOLLAR_DIR="../hollar"

if [ -z "${RPC:-}" ]; then
  echo "ERROR: set RPC=<https-or-http-url>  (e.g. https://rpc.hydradx.cloud, https://2.lark.hydration.cloud, http://localhost:8000)" >&2
  exit 1
fi
export RPC_URL="${RPC_URL:-$RPC}"
export WS_URL="${WS_URL:-$(printf '%s' "$RPC" | sed 's#^http#ws#')}"

PRIV_KEY="${PK:-${PRIV_KEY:-}}"
if [ -z "$PRIV_KEY" ]; then
  echo "ERROR: set PK=0x... (deployer private key)" >&2
  exit 1
fi
export PRIV_KEY

export MARKET_NAME="BIL"

# NETWORK = target hardhat network (= deployments dir). Default writes to
# deployments/hydration/ (mainnet's canonical dir). Override to lark2,
# chopsticks, etc. when forking.
NETWORK="${NETWORK:-hydration}"

# FORK drives both fork-mode AND config/deployment-dir resolution
# (`FORK ? FORK : hre.network.name`). It's ONLY needed when the target NETWORK
# has no BIL market-config keys of its own — lark2/nice/zombie/chopsticks
# resolve config via FORK=hydration. Networks that DO carry bil keys
# (currently only `hydration`) MUST run with FORK empty; otherwise address
# lookups in later phases read the wrong deployments dir.
case "$NETWORK" in
  hydration) export FORK="${FORK:-}" ;;
  *)         export FORK="${FORK:-hydration}" ;;
esac

# Mainnet addresses for the prerequisite contracts. These are the canonical
# Hydration-mainnet deployments and they exist verbatim on any state-fork
# (chopsticks, lark2) since those fork from mainnet.
HOLLAR_ADDRESS="0x531a654d1696ED52e7275A8cede955E82620f99a"
DECENTRAL_POOL_ADDRESS="0x207a626c07b73E76134177D1f44B0f32e94ADB5a"
DCL_PRECOMPILE_ADDRESS="0x0000000000000000000000000000000100000226"  # asset 550

HYDRATION_DEPLOYMENTS="deployments/hydration"
HOLLAR_NETWORK="${HOLLAR_NETWORK:-$NETWORK}"
HOLLAR_DEPLOY_DIR="$HOLLAR_DIR/deployments/$HOLLAR_NETWORK"

GHO_DEPLOY_TAG="${GHO_DEPLOY_TAG:-bil_hollar_deploy}"

CORE_ARTIFACTS=(
  Pool-Proxy-BIL.json Pool-Implementation.json
  PoolAddressesProvider-BIL.json PoolAddressesProviderRegistry.json
  PoolConfigurator-Implementation.json PoolConfigurator-Proxy-BIL.json
  ACLManager-BIL.json AaveOracle-BIL.json TreasuryProxy.json
)
GHO_ARTIFACTS=(
  GhoAToken-BIL GhoStableDebtToken-BIL
  GhoVariableDebtToken-BIL GhoInterestRateStrategy-BIL
)

# Chain-wide singletons reused from the existing Hydration deployment instead
# of redeployed. Safe because they carry no market-specific immutable. Seeded
# into the target deployments dir before phase 1 so hardhat-deploy reuses
# them. Disable with REUSE_HYDRATION_SINGLETONS=0.
#
# Each entry's reuse-justification:
#   - logic libraries: pure code, no constructor args
#   - ReservesSetupHelper: stateless
#   - PoolConfigurator-Implementation: no constructor args (provider is set
#     in proxy storage via initialize); the impl is pure logic, two markets'
#     proxies can delegate-call to the same impl
#   - ReserveStrategy-rateStrategyStables: BIL's only reserve has
#     borrowingEnabled=false, so the rate math is never executed. The
#     provider-immutable mismatch (strategy bound to Hydration's provider)
#     doesn't matter because no permissioned setters are called against it.
REUSE_HYDRATION_SINGLETONS="${REUSE_HYDRATION_SINGLETONS:-1}"
REUSABLE_ARTIFACTS=(
  SupplyLogic BorrowLogic LiquidationLogic EModeLogic
  BridgeLogic ConfiguratorLogic FlashLoanLogic PoolLogic
  ReservesSetupHelper
  PoolConfigurator-Implementation
  ReserveStrategy-rateStrategyStables
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

# Derive deployer EVM address from PK so the preflight checks the account we
# actually deploy with.
if [ -z "${DEPLOYER_EVM:-}" ]; then
  DEPLOYER_EVM="$(PRIV_KEY="$PRIV_KEY" node -e \
    "const e=require('ethers');const W=e.Wallet||e.ethers.Wallet;console.log(new W(process.env.PRIV_KEY).address)" \
    2>/dev/null || true)"
  [ -n "$DEPLOYER_EVM" ] || die "failed to derive DEPLOYER_EVM from PK — set DEPLOYER_EVM explicitly"
fi

# ---------------------------------------------------------------------------
# Preflight — verify preconditions (do not bootstrap)
# ---------------------------------------------------------------------------
phase "Preflight — target $RPC"
info "EVM RPC : $RPC"
info "network : $NETWORK   (FORK='${FORK}')"
info "deployer: $DEPLOYER_EVM"

[ -d "$HOLLAR_DIR" ] || die "hollar repo not found at $HOLLAR_DIR (needed for GHO impls)"
grep -q "$HOLLAR_NETWORK" "$HOLLAR_DIR/hardhat.config.ts" 2>/dev/null \
  || die "hollar/hardhat.config.ts does not register the '$HOLLAR_NETWORK' network"
[ -d "$HOLLAR_DIR/node_modules/hardhat" ] \
  || die "hollar deps not installed — run 'cd $HOLLAR_DIR && npm install' first"
[ -d "$HOLLAR_DIR/types" ] \
  || die "hollar not compiled — run 'cd $HOLLAR_DIR && npm run compile:hh' (GHO deploy imports typechain ../types)"

# 1) Decentral pool must respond to stablecoin() — vault initialize calls this
#    during _registerPool; if it reverts the whole deploy is wasted.
#    selector for stablecoin() = keccak256("stablecoin()")[:4] = 0xe9cbd822
sc="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$DECENTRAL_POOL_ADDRESS\",\"data\":\"0xe9cbd822\"},\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
# Case-insensitive substring match — eth_call returns lowercase hex; the
# canonical HOLLAR_ADDRESS we ship is mixed-case checksummed.
sc_lower="$(printf '%s' "$sc" | tr 'A-F' 'a-f')"
hollar_lower="$(printf '%s' "${HOLLAR_ADDRESS#0x}" | tr 'A-F' 'a-f')"
case "${sc_lower:?}" in
  *"$hollar_lower"*) info "Decentral pool stablecoin() → HOLLAR ✓" ;;
  *) die "Decentral pool $DECENTRAL_POOL_ADDRESS.stablecoin() did not return HOLLAR ($HOLLAR_ADDRESS) on $RPC. result: ${sc:-<empty/revert>}. Vault deploy WILL fail." ;;
esac

# 2) HOLLAR ERC20 must be on-chain.
hbal_sig="0x70a08231000000000000000000000000${DEPLOYER_EVM#0x}"
hcode="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$HOLLAR_ADDRESS\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
[ -n "$hcode" ] && [ "$hcode" != "0x" ] || die "HOLLAR contract $HOLLAR_ADDRESS not deployed on $RPC"
info "HOLLAR contract present"

# 3) Deployer must already hold gas (WETH is the EVM fee asset).
bal="$(rpc_call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_EVM\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
[ -n "$bal" ] && [ "$bal" != "0x0" ] \
  || die "deployer $DEPLOYER_EVM has no gas (WETH) on $RPC.
       Fund it and whitelist it as a contract creator first — these are
       preconditions, not deployment steps."
info "deployer funded (balance $bal)"

if [ "${ASSUME_YES:-}" != "1" ]; then
  read -r -p "Deploy BIL to $RPC (network=$NETWORK)? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "aborted"
fi

mkdir -p "deployments/${NETWORK}"

# ---------------------------------------------------------------------------
# Reuse chain-wide singletons from the existing Hydration deployment
# ---------------------------------------------------------------------------
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

phase "0a — deploy the BIL Vault (UUPS proxy + impl + QueueLib + BILOracle)"
info "Ports bil-vault/script/Deploy.s.sol to viem (see deploy-bil-vault.mjs)."
info "Records vault proxy + oracle addresses for later phases."
retry 3 env \
  PRIVATE_KEY="$PRIV_KEY" \
  RPC="$RPC" \
  node scripts/deploy-bil-vault.mjs | tee /tmp/bil-vault-deploy.log
# Parse the addresses block at the end of the dry-run output
VAULT_ADDRESS="$(sed -n 's/.*Proxy (Vault):[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p' /tmp/bil-vault-deploy.log | tail -1)"
BIL_ORACLE_ADDRESS="$(sed -n 's/.*BILOracle:[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p' /tmp/bil-vault-deploy.log | tail -1)"
[ -n "$VAULT_ADDRESS" ] || die "could not parse VAULT_ADDRESS from /tmp/bil-vault-deploy.log"
[ -n "$BIL_ORACLE_ADDRESS" ] || die "could not parse BIL_ORACLE_ADDRESS from /tmp/bil-vault-deploy.log"
info "VAULT_ADDRESS    = $VAULT_ADDRESS"
info "BIL_ORACLE       = $BIL_ORACLE_ADDRESS"
export VAULT_ADDRESS BIL_ORACLE_ADDRESS

phase "0b — post-deploy: grant GUARDIAN + CLAIM_OPERATOR, seed deposit"
# GUARDIAN/KEEPER/SEED_AMOUNT/NEW_ADMIN should be set in the operator's env;
# this step is idempotent (skips already-granted roles + already-seeded
# positions). Run NOW to grant operational roles BEFORE the proposal lands,
# then re-run with NEW_ADMIN=<gov> after Phase 5 to rotate vault roles to
# governance.
retry 3 env \
  VAULT_ADDRESS="$VAULT_ADDRESS" \
  PRIVATE_KEY="$PRIV_KEY" \
  RPC="$RPC" \
  node scripts/post-deploy-bil-vault.mjs

phase "1 — deploy BIL Aave market core (EVM)"
retry 5 npx hardhat deploy --tags market --network "$NETWORK"

phase "2 — deploy BILOracleAdapter against the vault"
info "Chainlink-V3 + IEACAggregatorProxy adapter; reads vault.exchangeRate()."
retry 3 npx hardhat deploy-BILOracleAdapter --vault "$VAULT_ADDRESS" --network "$NETWORK"
info "init-reserve auto-wires BILOracleAdapter as the BIL source"

phase "3 — deploy BILDepositZap (atomic HOLLAR→BIL→aBIL deposit helper)"
# Pool-Proxy-BIL exists after phase 1.
POOL_BIL="$(node -e "console.log(require('./deployments/${NETWORK}/Pool-Proxy-BIL.json').address)")"
retry 3 npx hardhat deploy-BILDepositZap \
  --hollar "$HOLLAR_ADDRESS" \
  --vault "$VAULT_ADDRESS" \
  --pool "$POOL_BIL" \
  --precompile "$DCL_PRECOMPILE_ADDRESS" \
  --network "$NETWORK"

phase "4 — deploy GHO impls (in hollar) + import"
mkdir -p "$HOLLAR_DEPLOY_DIR"
echo "222222" > "$HOLLAR_DEPLOY_DIR/.chainId"
for f in "${CORE_ARTIFACTS[@]}"; do
  [ -f "deployments/${NETWORK}/$f" ] || die "missing core artifact deployments/${NETWORK}/$f (did phase 1 finish?)"
  cp "deployments/${NETWORK}/$f" "$HOLLAR_DEPLOY_DIR/"
done
cp "$HYDRATION_DEPLOYMENTS/HOLLAR.json" "$HOLLAR_DEPLOY_DIR/GhoToken.json"

# CRITICAL: do NOT pass FORK here. hollar enters *fork mode* when FORK is set,
# which deploys the GHO impls to a throwaway local fork instead of the live
# network — leaving phantom impl addresses on-chain and bricking
# initReserves(HOLLAR) with "Cannot set a proxy implementation to a
# non-contract address".
( cd "$HOLLAR_DIR" \
  && MARKET_NAME=BIL FORK= RPC="$RPC" PRIV_KEY="$PRIV_KEY" \
     retry 3 npx hardhat deploy --tags "$GHO_DEPLOY_TAG" --network "$HOLLAR_NETWORK" ) \
  || die "hollar GHO deploy failed"

# Sanity: the deployed GhoAToken impl must actually have code on this network.
gho_impl="$(node -e "console.log(require('$HOLLAR_DEPLOY_DIR/GhoAToken-BIL.json').address)" 2>/dev/null || true)"
if [ -n "$gho_impl" ]; then
  code="$(curl -s "$RPC" -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$gho_impl\",\"latest\"]}" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
  [ -n "$code" ] && [ "$code" != "0x" ] || die "GhoAToken impl $gho_impl has NO CODE on $RPC — GHO deploy went to a fork/wrong chain"
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

phase "5 — hand market admin to governance, then fully revoke the deployer"
# Identical pattern to gigahdx phase 5 — ports cleanly because the Aave admin
# surface is the same regardless of market.
# idempotent (skips already-granted/revoked roles); retry absorbs transient 'nonce too low'
# 1) grant governance every role + transfer Ownable contracts to gov
retry 6 npx hardhat run scripts/bil/transfer-admin-to-governance.ts --network "$NETWORK"
# 2) grant risk admin to the ReservesSetupHelper (needs the deployer's DEFAULT_ADMIN)
retry 4 npx hardhat run scripts/grant-bil-risk-admin.ts --network "$NETWORK"
# 3) LAST: deployer renounces every role it still holds (gov is now sole admin).
#    Has a safety guard that refuses to run unless gov already holds DEFAULT_ADMIN+POOL_ADMIN.
retry 4 npx hardhat run scripts/bil/revoke-deployer.ts --network "$NETWORK"

# Also rotate the vault's own roles to governance now that the market is set up.
# post-deploy-bil-vault.mjs is idempotent — it only grants/renounces what isn't
# already in the target state.
phase "5b — rotate BIL Vault admin roles to governance"
retry 2 env \
  VAULT_ADDRESS="$VAULT_ADDRESS" \
  PRIVATE_KEY="$PRIV_KEY" \
  RPC="$RPC" \
  NEW_ADMIN="0xaa7e0000000000000000000000000000000aa7e0" \
  node scripts/post-deploy-bil-vault.mjs

phase "6 — generate the launch proposal preimage (MANUAL submission)"
info "one batch: assetRegistry register + initReserves(BIL) + setAssetSources"
info "        + ReservesSetupHelper configureReserves + setLiquidationProtocolFee"
info "        + PoolAddressesProviderRegistry register + initReserves(HOLLAR)"
info "        + setReserveBorrowing + HOLLAR.addFacilitator + GHO cross-refs"
info "        + assetRegistry(HDCL→aToken) + multiTransactionPayment fee currencies"
info "        + evmAccounts.approveContract(Pool-Proxy-BIL)"
info "        + stablepool bootstrap (asset 10055, BIL/HOLLAR peg via BILOracleAdapter)"
info "This PRINTS the encoded preimage hex + decoded tree and submits NOTHING."
info "Take the 'submit preimages' hex below and submit it as a referendum yourself."
npx hardhat bil --network "$NETWORK"

# ===========================================================================
# Address sheet (read-only)
# ===========================================================================
phase "7 — generate the address sheet"
npx hardhat run scripts/bil/generate-addresses.ts --network "$NETWORK"

phase "DONE — contracts deployed to $RPC; proposal preimage printed in Phase 6"
info "next: submit the Phase 6 preimage hex as a referendum manually and enact it,"
info "then come back and verify (or run scripts/bil/verify-readiness.ts)"
